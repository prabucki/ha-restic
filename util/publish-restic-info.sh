#!/usr/bin/env bash
# Publish restic stats + latest snapshot details for a target in one go.
# Usage: publish-restic-info.sh <target>

set -euo pipefail
JOB=$(basename "$0")
TARGET_INPUT=${1:?Usage: $0 <target>}
STATS_ATTR="{}"

# Load target (pre.sh logs start and sets TARGET env); TAG intentionally empty.
TAG="" source /etc/restic/targets/includes/pre.sh "$TARGET_INPUT"

log_msg() { echo "[publish][$TARGET] $1" >&2; }

publish_stats() {
  local TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
  local DEVICE_JSON="{ \"identifiers\": [\"restic-$TOPIC_TARGET\"], \"name\": \"Restic ($TARGET)\", \"manufacturer\": \"restic\", \"model\": \"restic-mqtt\" }"
  local BASE_TOPIC="homeassistant/sensor/restic"

  log_msg "Publishing stats"

  # Fetch stats once
  local RESTORE_SIZE=$(restic stats --json)
  local RAW_DATA=$(restic stats --json --mode raw-data)
  local TOTAL_RESTORE_SIZE=$(jq -r .total_size <<< "$RESTORE_SIZE")
  local TOTAL_RAW_DATA=$(jq -r .total_size <<< "$RAW_DATA")
  STATS_ATTR=$(jq -sc add <<< "$RESTORE_SIZE $RAW_DATA")

  # Publish sensor configs with proper numeric handling
  local RESTORE_TOPIC="$BASE_TOPIC-stats-$TOPIC_TARGET-restore-size"
  local RAW_TOPIC="$BASE_TOPIC-stats-$TOPIC_TARGET-raw-data"
  local REPO_TOPIC="$BASE_TOPIC-repo-$TOPIC_TARGET-size"
  local FILL_TOPIC="$BASE_TOPIC-repo-$TOPIC_TARGET-fill"

  $MOSQUITTO_PUB -r -t "$RESTORE_TOPIC/config" -m "{\"name\":\"restic stats $TARGET restore size\",\"state_topic\":\"$RESTORE_TOPIC/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"json_attributes_topic\":\"$RESTORE_TOPIC/attributes\",\"unique_id\":\"restic-stats-$TOPIC_TARGET-restore-size\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$RAW_TOPIC/config" -m "{\"name\":\"restic stats $TARGET raw data\",\"state_topic\":\"$RAW_TOPIC/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"json_attributes_topic\":\"$RAW_TOPIC/attributes\",\"unique_id\":\"restic-stats-$TOPIC_TARGET-raw-data\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/config" -m "{\"name\":\"Restic repo size ($TARGET)\",\"state_topic\":\"$REPO_TOPIC/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"json_attributes_topic\":\"$REPO_TOPIC/attributes\",\"unique_id\":\"restic-repo-$TOPIC_TARGET-size\",\"device\":$DEVICE_JSON}"
  $MOSQUITTO_PUB -r -t "$FILL_TOPIC/config" -m "{\"name\":\"Restic repo fill ($TARGET)\",\"state_topic\":\"$FILL_TOPIC/state\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\"json_attributes_topic\":\"$FILL_TOPIC/attributes\",\"unique_id\":\"restic-repo-$TOPIC_TARGET-fill\",\"device\":$DEVICE_JSON}"

  # Publish state and attributes
  $MOSQUITTO_PUB -r -t "$RESTORE_TOPIC/attributes" -m "$RESTORE_SIZE"
  $MOSQUITTO_PUB -r -t "$RESTORE_TOPIC/state" -m "$TOTAL_RESTORE_SIZE"
  $MOSQUITTO_PUB -r -t "$RAW_TOPIC/attributes" -m "$RAW_DATA"
  $MOSQUITTO_PUB -r -t "$RAW_TOPIC/state" -m "$TOTAL_RAW_DATA"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/attributes" -m "$STATS_ATTR"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/state" -m "$TOTAL_RAW_DATA"

  # Calculate and publish fill percentage if DISK_SIZE is set
  if [[ -n "${DISK_SIZE:-}" ]] && [[ "$DISK_SIZE" -gt 0 ]] 2>/dev/null; then
    local FILL_PCT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RAW_DATA/$DISK_SIZE)*100}")
    local FILL_ATTR=$(jq -c --argjson fill "$FILL_PCT" '. + {fill_percent:$fill}' <<< "$STATS_ATTR")
    $MOSQUITTO_PUB -r -t "$FILL_TOPIC/attributes" -m "$FILL_ATTR"
    $MOSQUITTO_PUB -r -t "$FILL_TOPIC/state" -m "$FILL_PCT"
    log_msg "Repo fill: ${FILL_PCT}%"
  fi
}

publish_snapshots() {
  local THRESHOLD_SEC=$(((${HEALTH_THRESHOLD_HOURS:-36})*3600))
  local NOW_TS=$(date +%s)
  local TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
  local DEVICE_JSON="{ \"identifiers\": [\"restic-$TOPIC_TARGET\"], \"name\": \"Restic ($TARGET)\", \"manufacturer\": \"restic\", \"model\": \"restic-mqtt\" }"

  log_msg "Publishing snapshots (threshold ${HEALTH_THRESHOLD_HOURS:-36}h)"

  while IFS= read -r TAG; do
    local TOPIC_TAG=$(sanitize_topic_component "$TAG")
    local BASE="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"
    
    # Fetch all snapshot data
    local SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
    local SNAPSHOT_COUNT=$(jq length <<< "$SNAPSHOT_LIST")
    local SNAPSHOT=$(jq -c '.[0] // {}' <<< "$SNAPSHOT_LIST")
    local SNAPSHOT_ID=$(jq -r '.short_id // .id // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TIME=$(jq -r '.time // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TS=$(date -d "$SNAPSHOT_TIME" +%s 2>/dev/null || echo "0")
    local AGE_SEC=$((NOW_TS-SNAPSHOT_TS))
    
    # Determine health
    local HEALTH="missing"
    [[ -n "$SNAPSHOT_ID" ]] && HEALTH="ok"
    [[ $SNAPSHOT_TS -gt 0 && $AGE_SEC -gt $THRESHOLD_SEC ]] && HEALTH="stale"

    # Fetch stats if snapshot exists
    local RESTORE_STATS="{}" RAW_STATS="{}"
    if [[ -n "$SNAPSHOT_ID" ]]; then
      RESTORE_STATS=$(restic stats "$SNAPSHOT_ID" --json 2>/dev/null || echo "{}")
      RAW_STATS=$(restic stats "$SNAPSHOT_ID" --json --mode raw-data 2>/dev/null || echo "{}")
    fi

    log_msg "$TAG: id=${SNAPSHOT_ID:-none} age=${AGE_SEC}s health=$HEALTH count=$SNAPSHOT_COUNT"

    # Extract individual values
    local TOTAL_RESTORE_SIZE=$(jq -r '.total_size // 0' <<< "$RESTORE_STATS")
    local TOTAL_FILE_COUNT=$(jq -r '.total_file_count // 0' <<< "$RESTORE_STATS")
    local TOTAL_UNCOMPRESSED=$(jq -r '.total_uncompressed_size // 0' <<< "$RESTORE_STATS")
    local COMPRESSION_RATIO=$(jq -r '.compression_ratio // 1' <<< "$RESTORE_STATS")
    local COMPRESSION_PROGRESS=$(jq -r '.compression_progress // 0' <<< "$RESTORE_STATS")
    local COMPRESSION_SAVING=$(jq -r '.compression_space_saving // 0' <<< "$RESTORE_STATS")
    local TOTAL_BLOB_COUNT=$(jq -r '.total_blob_count // 0' <<< "$RESTORE_STATS")
    local TOTAL_RAW_DATA=$(jq -r '.total_size // 0' <<< "$RAW_STATS")
    
    # Calculate fill percentage
    local FILL_PCT="0"
    if [[ -n "${DISK_SIZE:-}" ]] && [[ "$DISK_SIZE" -gt 0 ]] && [[ "$TOTAL_RAW_DATA" -gt 0 ]] 2>/dev/null; then
      FILL_PCT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RAW_DATA/$DISK_SIZE)*100}")
    fi

    # Publish individual sensors
    local FRIENDLY="${TAG//:/ }"
    
    # Health sensor
    $MOSQUITTO_PUB -r -t "$BASE-health/config" -m "{\"name\":\"$TARGET $FRIENDLY Health\",\"state_topic\":\"$BASE-health/state\",\"icon\":\"mdi:heart-pulse\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-health\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-health/state" -m "$HEALTH"
    
    # Snapshot ID
    $MOSQUITTO_PUB -r -t "$BASE-id/config" -m "{\"name\":\"$TARGET $FRIENDLY Snapshot ID\",\"state_topic\":\"$BASE-id/state\",\"icon\":\"mdi:identifier\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-id\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-id/state" -m "${SNAPSHOT_ID:-none}"
    
    # Snapshot time
    $MOSQUITTO_PUB -r -t "$BASE-time/config" -m "{\"name\":\"$TARGET $FRIENDLY Snapshot Time\",\"state_topic\":\"$BASE-time/state\",\"device_class\":\"timestamp\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-time\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-time/state" -m "$SNAPSHOT_TIME"
    
    # Age in seconds
    $MOSQUITTO_PUB -r -t "$BASE-age/config" -m "{\"name\":\"$TARGET $FRIENDLY Age\",\"state_topic\":\"$BASE-age/state\",\"unit_of_measurement\":\"s\",\"device_class\":\"duration\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-age\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-age/state" -m "$AGE_SEC"
    
    # Snapshot count
    $MOSQUITTO_PUB -r -t "$BASE-count/config" -m "{\"name\":\"$TARGET $FRIENDLY Snapshot Count\",\"state_topic\":\"$BASE-count/state\",\"icon\":\"mdi:counter\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-count/state" -m "$SNAPSHOT_COUNT"
    
    # Total restore size
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/config" -m "{\"name\":\"$TARGET $FRIENDLY Restore Size\",\"state_topic\":\"$BASE-restore-size/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-restore-size\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-restore-size/state" -m "$TOTAL_RESTORE_SIZE"
    
    # File count
    $MOSQUITTO_PUB -r -t "$BASE-file-count/config" -m "{\"name\":\"$TARGET $FRIENDLY File Count\",\"state_topic\":\"$BASE-file-count/state\",\"icon\":\"mdi:file-multiple\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-file-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-file-count/state" -m "$TOTAL_FILE_COUNT"
    
    # Uncompressed size
    $MOSQUITTO_PUB -r -t "$BASE-uncompressed/config" -m "{\"name\":\"$TARGET $FRIENDLY Uncompressed Size\",\"state_topic\":\"$BASE-uncompressed/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-uncompressed\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-uncompressed/state" -m "$TOTAL_UNCOMPRESSED"
    
    # Compression ratio
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/config" -m "{\"name\":\"$TARGET $FRIENDLY Compression Ratio\",\"state_topic\":\"$BASE-compression-ratio/state\",\"icon\":\"mdi:compress\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-ratio\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-ratio/state" -m "$COMPRESSION_RATIO"
    
    # Compression space saving
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/config" -m "{\"name\":\"$TARGET $FRIENDLY Compression Saving\",\"state_topic\":\"$BASE-compression-saving/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:percent\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-compression-saving\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-compression-saving/state" -m "$COMPRESSION_SAVING"
    
    # Blob count
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/config" -m "{\"name\":\"$TARGET $FRIENDLY Blob Count\",\"state_topic\":\"$BASE-blob-count/state\",\"icon\":\"mdi:database\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-blob-count\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-blob-count/state" -m "$TOTAL_BLOB_COUNT"
    
    # Raw data (actual repo size)
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/config" -m "{\"name\":\"$TARGET $FRIENDLY Raw Data\",\"state_topic\":\"$BASE-raw-data/state\",\"unit_of_measurement\":\"B\",\"device_class\":\"data_size\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-raw-data\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$BASE-raw-data/state" -m "$TOTAL_RAW_DATA"
    
    # Fill percentage (if DISK_SIZE is set)
    if [[ "$FILL_PCT" != "0" ]]; then
      $MOSQUITTO_PUB -r -t "$BASE-fill/config" -m "{\"name\":\"$TARGET $FRIENDLY Fill\",\"state_topic\":\"$BASE-fill/state\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:gauge\",\"state_class\":\"measurement\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET-fill\",\"device\":$DEVICE_JSON}"
      $MOSQUITTO_PUB -r -t "$BASE-fill/state" -m "$FILL_PCT"
    fi
    
  done < <(/etc/restic/util/list-tags.sh "$TARGET")
}

publish_stats
publish_snapshots
log_msg "Finished"
