#!/usr/bin/env bash
# Publish restic stats + latest snapshot details for a target in one go.
# Usage: publish-restic-info.sh <target>

set -euo pipefail
JOB=$(basename "$0")
TARGET_INPUT=${1:?Usage: $0 <target>}
STATS_ATTR="{}"

# Load target (pre.sh logs start and sets TARGET env); TAG intentionally empty.
TAG="" source /etc/restic/targets/includes/pre.sh "$TARGET_INPUT"

# Initialize global variables after pre.sh is sourced (so sanitize_topic_component is available)
TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
DEVICE_JSON="{ \"identifiers\": [\"restic-$TOPIC_TARGET\"], \"name\": \"Restic ($TARGET)\", \"manufacturer\": \"restic\", \"model\": \"restic-mqtt\" }"
TAG="plan:bojanobackup"
TOPIC_TAG=$(sanitize_topic_component "$TAG")
BASE="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"

log_msg() { echo "[publish][$TARGET] $1" >&2; }

# Function to check repository connectivity
check_repo_connectivity() {
  log_msg "Checking repository connectivity"
  set +e  # Temporarily disable exit on error
  local CHECK_OUTPUT
  CHECK_OUTPUT=$(restic snapshots --json 2>&1)
  local EXIT_CODE=$?
  set -e  # Re-enable exit on error

  if [[ $EXIT_CODE -ne 0 ]]; then
    if echo "$CHECK_OUTPUT" | grep -qE "ssh: connect to host|No route to host|Connection refused|unable to start the sftp session|Connection timed out|server unexpectedly closed connection"; then
      log_msg "Repository is offline (SSH/SFTP connection failed)"
      return 1
    fi
    # For other errors, let them propagate
    log_msg "Repository check failed with unexpected error (exit code: $EXIT_CODE)"
    echo "$CHECK_OUTPUT" >&2
    exit $EXIT_CODE
  fi

  log_msg "Repository is online"
  return 0
}

# Function to publish offline status
publish_offline_status() {
  log_msg "Publishing offline status"

  # Publish operation status as offline
  $MOSQUITTO_PUB -r -t "$BASE-operation/config" -m "{\"name\":\"Operation Status\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_operation\",\"state_topic\":\"$BASE-operation/state\",\"icon\":\"mdi:server-network-off\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-operation\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$BASE-operation/state" -m "offline"

  log_msg "Published offline status"
}

publish_snapshots() {

  while IFS= read -r TAG; do
    [[ -z "$TAG" ]] && continue  # Skip empty lines

    # Only process tags starting with "plan:" to avoid duplicates
    if [[ ! "$TAG" =~ ^plan: ]]; then
      log_msg "Skipping tag: $TAG (not a plan tag)"
      continue
    fi

    log_msg "Processing tag: $TAG"

    # Fetch all snapshot data
    local SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
    local SNAPSHOT_COUNT=$(jq length <<< "$SNAPSHOT_LIST")
    local SNAPSHOT=$(jq -c '.[0] // {}' <<< "$SNAPSHOT_LIST")
    local SNAPSHOT_ID=$(jq -r '.short_id // .id // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TIME=$(jq -r '.time // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TS=$(date -d "$SNAPSHOT_TIME" +%s 2>/dev/null || echo "0")

    # Check for running restic operations
    local OPERATION_STATUS="idle"
    local OPERATION_PROGRESS="0"
    local RESTIC_PID=$(pgrep -f "restic.*$TARGET" | head -n1)
    if [[ -n "$RESTIC_PID" ]]; then
      local CMD=$(ps -p "$RESTIC_PID" -o args= 2>/dev/null || echo "")
      if [[ "$CMD" =~ backup ]]; then
        OPERATION_STATUS="backup"
      elif [[ "$CMD" =~ prune ]]; then
        OPERATION_STATUS="prune"
      elif [[ "$CMD" =~ check ]]; then
        OPERATION_STATUS="check"
      elif [[ "$CMD" =~ verify ]]; then
        OPERATION_STATUS="verify"
      elif [[ "$CMD" =~ restore ]]; then
        OPERATION_STATUS="restore"
      elif [[ "$CMD" =~ forget ]]; then
        OPERATION_STATUS="forget"
      else
        OPERATION_STATUS="running"
      fi
      log_msg "Detected running operation: $OPERATION_STATUS (PID: $RESTIC_PID)"
    fi

    # Fetch stats if snapshot exists
    local RESTORE_STATS="{}" RAW_STATS="{}"
    if [[ -n "$SNAPSHOT_ID" ]]; then
      RESTORE_STATS=$(restic stats "$SNAPSHOT_ID" --json 2>/dev/null || echo "{}")
      RAW_STATS=$(restic stats "$SNAPSHOT_ID" --json --mode raw-data 2>/dev/null || echo "{}")
    fi

    log_msg "$TAG: id=${SNAPSHOT_ID:-none} count=$SNAPSHOT_COUNT"

    # Extract individual values
    local TOTAL_RESTORE_SIZE=$(jq -r '.total_size // 0' <<< "$RESTORE_STATS")
    local TOTAL_FILE_COUNT=$(jq -r '.total_file_count // 0' <<< "$RESTORE_STATS")
    local TOTAL_UNCOMPRESSED=$(jq -r '.total_uncompressed_size // null' <<< "$RESTORE_STATS")
    local COMPRESSION_RATIO=$(jq -r '.compression_ratio // null' <<< "$RESTORE_STATS")
    local COMPRESSION_PROGRESS=$(jq -r '.compression_progress // 0' <<< "$RESTORE_STATS")
    local COMPRESSION_SAVING=$(jq -r '.compression_space_saving // null' <<< "$RESTORE_STATS")
    local TOTAL_BLOB_COUNT=$(jq -r '.total_blob_count // null' <<< "$RESTORE_STATS")
    local TOTAL_RAW_DATA=$(jq -r '.total_size // 0' <<< "$RAW_STATS")

    # If compression stats are not available, calculate manually
    if [[ "$TOTAL_UNCOMPRESSED" == "null" ]] || [[ "$TOTAL_UNCOMPRESSED" == "0" ]]; then
      TOTAL_UNCOMPRESSED="$TOTAL_RESTORE_SIZE"
    fi

    # Calculate compression ratio if not provided
    if [[ "$COMPRESSION_RATIO" == "null" ]] && [[ "$TOTAL_UNCOMPRESSED" != "0" ]] && [[ "$TOTAL_RAW_DATA" != "0" ]]; then
      COMPRESSION_RATIO=$(awk "BEGIN {printf \"%.2f\", $TOTAL_UNCOMPRESSED/$TOTAL_RAW_DATA}")
    elif [[ "$COMPRESSION_RATIO" == "null" ]]; then
      COMPRESSION_RATIO="1.00"
    fi

    # Calculate compression saving if not provided
    if [[ "$COMPRESSION_SAVING" == "null" ]] && [[ "$TOTAL_UNCOMPRESSED" != "0" ]] && [[ "$TOTAL_RAW_DATA" != "0" ]]; then
      COMPRESSION_SAVING=$(awk "BEGIN {printf \"%.2f\", (1-$TOTAL_RAW_DATA/$TOTAL_UNCOMPRESSED)*100}")
    elif [[ "$COMPRESSION_SAVING" == "null" ]]; then
      COMPRESSION_SAVING="0"
    fi

    # Get blob count from raw stats if not in restore stats
    if [[ "$TOTAL_BLOB_COUNT" == "null" ]]; then
      TOTAL_BLOB_COUNT=$(jq -r '.total_blob_count // 0' <<< "$RAW_STATS")
    fi

    # Calculate fill percentage
    local FILL_PCT="0"
    if [[ -n "${DISK_SIZE:-}" ]] && [[ "$DISK_SIZE" -gt 0 ]] && [[ "$TOTAL_RAW_DATA" -gt 0 ]] 2>/dev/null; then
      FILL_PCT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RAW_DATA/$DISK_SIZE)*100}")
    fi

    # Publish individual sensors
    local FRIENDLY="${TAG//:/ }"

    # Operation status sensor
    $MOSQUITTO_PUB -r -t "$BASE-operation/config" -m "{\"name\":\"Operation Status\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_operation\",\"state_topic\":\"$BASE-operation/state\",\"icon\":\"mdi:cog\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-operation\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-operation/state" -m "$OPERATION_STATUS"

    # Snapshot ID
    $MOSQUITTO_PUB -r -t "$BASE-id/config" -m "{\"name\":\"Snapshot ID\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_id\",\"state_topic\":\"$BASE-id/state\",\"icon\":\"mdi:identifier\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-id\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-id/state" -m "${SNAPSHOT_ID:-none}"

    # Snapshot time
    $MOSQUITTO_PUB -r -t "$BASE-time/config" -m "{\"name\":\"Snapshot Time\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_time\",\"state_topic\":\"$BASE-time/state\",\"device_class\":\"timestamp\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-time\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-time/state" -m "$SNAPSHOT_TIME"

    # Snapshot count
    $MOSQUITTO_PUB -r -t "$BASE-count/config" -m "{\"name\":\"Snapshot Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_count\",\"state_topic\":\"$BASE-count/state\",\"icon\":\"mdi:counter\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-count/state" -m "$SNAPSHOT_COUNT"

    # Total restore size
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/config" -m "{\"name\":\"Restore Size\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_restore_size\",\"state_topic\":\"$BASE-restore-size/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-restore-size\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/state" -m "$TOTAL_RESTORE_SIZE"

    # File count
    $MOSQUITTO_PUB -r -t "$BASE-file-count/config" -m "{\"name\":\"File Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_file_count\",\"state_topic\":\"$BASE-file-count/state\",\"icon\":\"mdi:file-multiple\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-file-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-file-count/state" -m "$TOTAL_FILE_COUNT"

    # Compression ratio
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/config" -m "{\"name\":\"Compression Ratio\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_compression_ratio\",\"state_topic\":\"$BASE-compression-ratio/state\",\"icon\":\"mdi:compress\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-ratio\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/state" -m "$COMPRESSION_RATIO"

    # Compression space saving
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/config" -m "{\"name\":\"Compression Saving\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_compression_saving\",\"state_topic\":\"$BASE-compression-saving/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:percent\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-saving\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/state" -m "$COMPRESSION_SAVING"

    # Blob count
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/config" -m "{\"name\":\"Blob Count\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_blob_count\",\"state_topic\":\"$BASE-blob-count/state\",\"icon\":\"mdi:database\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-blob-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/state" -m "$TOTAL_BLOB_COUNT"

    # Raw data (actual repo size)
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/config" -m "{\"name\":\"Raw Data\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_raw_data\",\"state_topic\":\"$BASE-raw-data/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-raw-data\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/state" -m "$TOTAL_RAW_DATA"

    # Fill percentage (if DISK_SIZE is set)
    if [[ "$FILL_PCT" != "0" ]]; then
      $MOSQUITTO_PUB -r -t "$BASE-fill/config" -m "{\"name\":\"Fill\",\"object_id\":\"restic_${TOPIC_TARGET}_${TOPIC_TAG}_fill\",\"state_topic\":\"$BASE-fill/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:gauge\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-fill\",\"device\":$DEVICE_JSON}"
      $MOSQUITTO_PUB -r -t "$BASE-fill/state" -m "$FILL_PCT"
    fi

    log_msg "Finished processing tag: $TAG"

  done < <(/etc/restic/util/list-tags.sh "$TARGET" | sort -u)
}

# Check repository connectivity first
if ! check_repo_connectivity; then
  log_msg "Server is offline - publishing offline status"
  publish_offline_status
  log_msg "Finished (offline)"
  exit 0
fi

log_msg "Server is online - publishing snapshot data"
publish_snapshots
log_msg "Finished"
