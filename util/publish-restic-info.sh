#!/usr/bin/env bash
# Publish restic stats + latest snapshot details for a target in one go.
# Usage: publish-restic-info.sh <target>

set -euo pipefail
JOB=$(basename "$0")
TARGET_INPUT=${1:?Usage: $0 <target>}

# Load target (pre.sh logs start and sets TARGET env); TAG intentionally empty.
TAG="" source /etc/restic/targets/includes/pre.sh "$TARGET_INPUT"

# Initialize global variables after pre.sh is sourced
TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
DEVICE_JSON="{ \"identifiers\": [\"restic-$TOPIC_TARGET\"], \"name\": \"Restic ($TARGET)\", \"manufacturer\": \"restic\", \"model\": \"restic-mqtt\" }"
TAG="plan:bojanobackup"
TOPIC_TAG=$(sanitize_topic_component "$TAG")
BASE="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"

log_msg() { echo "[publish][$TARGET] $1" >&2; }

# Check backup health from systemd journal
check_backup_health() {
  journalctl -u backrest.service --no-pager 2>/dev/null | grep -q "ERROR.*backup for plan \"BojanoBackup\"" && echo "FAILED" || echo "OK"
}

# Detect running operation status
get_operation_status() {
  local DEFAULT_STATUS=${1:-idle}
  local RESTIC_PID=$(pgrep -f "^restic .* $TARGET" | head -n1)

  [[ -z "$RESTIC_PID" ]] && { echo "$DEFAULT_STATUS"; return; }

  local CMD=$(ps -p "$RESTIC_PID" -o args= 2>/dev/null || echo "")
  log_msg "Found restic PID $RESTIC_PID"

  if [[ "$CMD" =~ backup ]]; then echo "backup"
  elif [[ "$CMD" =~ prune ]]; then echo "prune"
  elif [[ "$CMD" =~ check ]]; then echo "check"
  elif [[ "$CMD" =~ verify ]]; then echo "verify"
  elif [[ "$CMD" =~ restore ]]; then echo "restore"
  elif [[ "$CMD" =~ forget ]]; then echo "forget"
  else echo "running"; fi
}

# Publish health and operation status sensors
publish_status_sensors() {
  local HEALTH=$1
  local OPERATION_STATUS=$2

  $MOSQUITTO_PUB -r -t "$BASE-health/config" -m "{\"name\":\"Health\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_health\",\"state_topic\":\"$BASE-health/state\",\"icon\":\"mdi:heart-pulse\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-health\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$BASE-health/state" -m "$HEALTH"

  $MOSQUITTO_PUB -r -t "$BASE-operation/config" -m "{\"name\":\"Operation Status\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_operation\",\"state_topic\":\"$BASE-operation/state\",\"icon\":\"mdi:cog\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-operation\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$BASE-operation/state" -m "$OPERATION_STATUS"
}

# Check repository connectivity
check_repo_connectivity() {
  log_msg "Checking repository connectivity"
  set +e
  local CHECK_OUTPUT=$(restic snapshots --json 2>&1)
  local EXIT_CODE=$?
  set -e

  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "$CHECK_OUTPUT" | grep -qE "repository is already locked|unable to create lock in backend" && { log_msg "Repository locked"; return 0; }
    echo "$CHECK_OUTPUT" | grep -qE "ssh: connect to host|No route to host|Connection refused|unable to start the sftp session|Connection timed out|server unexpectedly closed connection" && { log_msg "Repository offline"; return 1; }
    log_msg "Repository check failed (exit code: $EXIT_CODE)"
    echo "$CHECK_OUTPUT" >&2
    exit $EXIT_CODE
  fi

  log_msg "Repository online"
  return 0
}

# Publish offline status
publish_offline_status() {
  log_msg "Publishing offline status"
  publish_status_sensors "$(check_backup_health)" "offline"
}

# Publish snapshots
publish_snapshots() {
  log_msg "Publishing snapshots"

  # Get tag list - handle lock errors
  set +e
  local TAGS_STDERR=$(mktemp)
  local TAGS_OUTPUT=$(/etc/restic/util/list-tags.sh "$TARGET" 2>"$TAGS_STDERR" | sort -u)
  local TAGS_EXIT_CODE=$?
  local STDERR_CONTENT=$(cat "$TAGS_STDERR")
  rm -f "$TAGS_STDERR"
  set -e

  # If repository is locked, publish status only
  if [[ $TAGS_EXIT_CODE -ne 0 ]] || echo "$STDERR_CONTENT" | grep -qE "repository is already locked|unable to create lock in backend"; then
    log_msg "Repository locked, publishing status only"
    publish_status_sensors "$(check_backup_health)" "$(get_operation_status locked)"
    return 0
  fi

  while IFS= read -r TAG; do
    [[ -z "$TAG" || ! "$TAG" =~ ^plan: ]] && continue

    log_msg "Processing tag: $TAG"

    # Fetch snapshot data
    local SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
    local SNAPSHOT_COUNT=$(jq length <<< "$SNAPSHOT_LIST")
    local SNAPSHOT=$(jq -c '.[0] // {}' <<< "$SNAPSHOT_LIST")
    local SNAPSHOT_ID=$(jq -r '.short_id // .id // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TIME=$(jq -r '.time // ""' <<< "$SNAPSHOT")

    # Get stats if snapshot exists
    local RESTORE_STATS="{}" RAW_STATS="{}"
    if [[ -n "$SNAPSHOT_ID" ]]; then
      RESTORE_STATS=$(restic stats "$SNAPSHOT_ID" --json 2>/dev/null || echo "{}")
      RAW_STATS=$(restic stats "$SNAPSHOT_ID" --json --mode raw-data 2>/dev/null || echo "{}")
    fi

    # Extract values
    local TOTAL_RESTORE_SIZE=$(jq -r '.total_size // 0' <<< "$RESTORE_STATS")
    local TOTAL_FILE_COUNT=$(jq -r '.total_file_count // 0' <<< "$RESTORE_STATS")
    local TOTAL_UNCOMPRESSED=$(jq -r '.total_uncompressed_size // null' <<< "$RESTORE_STATS")
    local COMPRESSION_RATIO=$(jq -r '.compression_ratio // null' <<< "$RESTORE_STATS")
    local COMPRESSION_SAVING=$(jq -r '.compression_space_saving // null' <<< "$RESTORE_STATS")
    local TOTAL_BLOB_COUNT=$(jq -r '.total_blob_count // null' <<< "$RESTORE_STATS")
    local TOTAL_RAW_DATA=$(jq -r '.total_size // 0' <<< "$RAW_STATS")

    # Calculate compression stats if not available
    [[ "$TOTAL_UNCOMPRESSED" == "null" || "$TOTAL_UNCOMPRESSED" == "0" ]] && TOTAL_UNCOMPRESSED="$TOTAL_RESTORE_SIZE"
    if [[ "$COMPRESSION_RATIO" == "null" ]] && [[ "$TOTAL_UNCOMPRESSED" != "0" ]] && [[ "$TOTAL_RAW_DATA" != "0" ]]; then
      COMPRESSION_RATIO=$(awk "BEGIN {printf \"%.2f\", $TOTAL_UNCOMPRESSED/$TOTAL_RAW_DATA}")
    elif [[ "$COMPRESSION_RATIO" == "null" ]]; then
      COMPRESSION_RATIO="1.00"
    fi
    if [[ "$COMPRESSION_SAVING" == "null" ]] && [[ "$TOTAL_UNCOMPRESSED" != "0" ]] && [[ "$TOTAL_RAW_DATA" != "0" ]]; then
      COMPRESSION_SAVING=$(awk "BEGIN {printf \"%.2f\", (1-$TOTAL_RAW_DATA/$TOTAL_UNCOMPRESSED)*100}")
    elif [[ "$COMPRESSION_SAVING" == "null" ]]; then
      COMPRESSION_SAVING="0"
    fi
    [[ "$TOTAL_BLOB_COUNT" == "null" ]] && TOTAL_BLOB_COUNT=$(jq -r '.total_blob_count // 0' <<< "$RAW_STATS")

    local FILL_PCT="0"
    [[ -n "${DISK_SIZE:-}" ]] && [[ "$DISK_SIZE" -gt 0 ]] && [[ "$TOTAL_RAW_DATA" -gt 0 ]] 2>/dev/null && FILL_PCT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RAW_DATA/$DISK_SIZE)*100}")

    # Publish sensors
    publish_status_sensors "$(check_backup_health)" "$(get_operation_status idle)"
    $MOSQUITTO_PUB -r -t "$BASE-id/config" -m "{\"name\":\"Snapshot ID\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_id\",\"state_topic\":\"$BASE-id/state\",\"icon\":\"mdi:identifier\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-id\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-id/state" -m "${SNAPSHOT_ID:-none}"
    $MOSQUITTO_PUB -r -t "$BASE-time/config" -m "{\"name\":\"Snapshot Time\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_time\",\"state_topic\":\"$BASE-time/state\",\"device_class\":\"timestamp\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-time\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-time/state" -m "$SNAPSHOT_TIME"
    $MOSQUITTO_PUB -r -t "$BASE-count/config" -m "{\"name\":\"Snapshot Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_count\",\"state_topic\":\"$BASE-count/state\",\"icon\":\"mdi:counter\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-count/state" -m "$SNAPSHOT_COUNT"
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/config" -m "{\"name\":\"Restore Size\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_restore_size\",\"state_topic\":\"$BASE-restore-size/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-restore-size\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/state" -m "$TOTAL_RESTORE_SIZE"
    $MOSQUITTO_PUB -r -t "$BASE-file-count/config" -m "{\"name\":\"File Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_file_count\",\"state_topic\":\"$BASE-file-count/state\",\"icon\":\"mdi:file-multiple\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-file-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-file-count/state" -m "$TOTAL_FILE_COUNT"
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/config" -m "{\"name\":\"Compression Ratio\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_compression_ratio\",\"state_topic\":\"$BASE-compression-ratio/state\",\"icon\":\"mdi:compress\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-ratio\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/state" -m "$COMPRESSION_RATIO"
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/config" -m "{\"name\":\"Compression Saving\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_compression_saving\",\"state_topic\":\"$BASE-compression-saving/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:percent\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-saving\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/state" -m "$COMPRESSION_SAVING"
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/config" -m "{\"name\":\"Blob Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_blob_count\",\"state_topic\":\"$BASE-blob-count/state\",\"icon\":\"mdi:database\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-blob-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/state" -m "$TOTAL_BLOB_COUNT"
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/config" -m "{\"name\":\"Raw Data\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_raw_data\",\"state_topic\":\"$BASE-raw-data/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-raw-data\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/state" -m "$TOTAL_RAW_DATA"
    [[ "$FILL_PCT" != "0" ]] && {
      $MOSQUITTO_PUB -r -t "$BASE-fill/config" -m "{\"name\":\"Fill\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_fill\",\"state_topic\":\"$BASE-fill/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:gauge\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-fill\",\"device\":$DEVICE_JSON}"
      $MOSQUITTO_PUB -r -t "$BASE-fill/state" -m "$FILL_PCT"
    }

    log_msg "Finished processing tag: $TAG"
  done <<< "$TAGS_OUTPUT"
}

# Main execution
check_repo_connectivity || { publish_offline_status; log_msg "Finished (offline)"; exit 0; }
publish_snapshots
log_msg "Finished"
