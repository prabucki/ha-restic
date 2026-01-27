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

  # Publish configs
  local TOPICS=("stats-$TOPIC_TARGET-restore-size" "stats-$TOPIC_TARGET-raw-data" "repo-$TOPIC_TARGET-size" "repo-$TOPIC_TARGET-fill")
  local NAMES=("restic stats $TARGET restore size" "restic stats $TARGET raw data" "Restic repo size ($TARGET)" "Restic repo fill ($TARGET)")
  for i in {0..3}; do
    local TOPIC="$BASE_TOPIC-${TOPICS[$i]}"
    local CONFIG="{ \"name\": \"${NAMES[$i]}\", \"state_topic\": \"$TOPIC/state\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$TOPIC/attributes\", \"unique_id\": \"restic-${TOPICS[$i]}\", \"device\": $DEVICE_JSON"
    [[ $i -lt 2 ]] && CONFIG+=", \"value_template\": \"{{ value | filesizeformat() }}\" }"
    [[ $i -eq 2 ]] && CONFIG+=", \"value_template\": \"{{ value | filesizeformat() }}\" }"
    [[ $i -eq 3 ]] && CONFIG="{\"name\":\"${NAMES[$i]}\",\"state_topic\":\"$TOPIC/state\",\"unit_of_measurement\":\"%\",\"device_class\":\"battery\",\"json_attributes_topic\":\"$TOPIC/attributes\",\"unique_id\":\"restic-${TOPICS[$i]}\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$TOPIC/config" -m "$CONFIG"
  done

  # Publish state and attributes
  local RESTORE_TOPIC="$BASE_TOPIC-stats-$TOPIC_TARGET-restore-size"
  local RAW_TOPIC="$BASE_TOPIC-stats-$TOPIC_TARGET-raw-data"
  local REPO_TOPIC="$BASE_TOPIC-repo-$TOPIC_TARGET-size"
  $MOSQUITTO_PUB -r -t "$RESTORE_TOPIC/attributes" -m "$RESTORE_SIZE"
  $MOSQUITTO_PUB -r -t "$RESTORE_TOPIC/state" -m "$TOTAL_RESTORE_SIZE"
  $MOSQUITTO_PUB -r -t "$RAW_TOPIC/attributes" -m "$RAW_DATA"
  $MOSQUITTO_PUB -r -t "$RAW_TOPIC/state" -m "$TOTAL_RAW_DATA"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/attributes" -m "$STATS_ATTR"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/state" -m "$TOTAL_RAW_DATA"

  # Calculate and publish fill percentage if DISK_SIZE is set
  if [[ -n "${DISK_SIZE:-}" ]] && [[ "$DISK_SIZE" -gt 0 ]] 2>/dev/null; then
    local FILL_PCT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_RAW_DATA/$DISK_SIZE)*100}")
    local FILL_TOPIC="$BASE_TOPIC-repo-$TOPIC_TARGET-fill"
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
    
    # Fetch all snapshot data in one call
    local SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
    local SNAPSHOT_COUNT=$(jq length <<< "$SNAPSHOT_LIST")
    local SNAPSHOT=$(jq -c '.[0] // {}' <<< "$SNAPSHOT_LIST")
    local SNAPSHOT_ID=$(jq -r '.short_id // .id // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TIME=$(jq -r '.time // ""' <<< "$SNAPSHOT")
    local SNAPSHOT_TS=$(date -d "$SNAPSHOT_TIME" +%s 2>/dev/null || echo "0")
    local AGE_SEC=$((NOW_TS-SNAPSHOT_TS))
    
    # Determine status and health
    local STATUS="Unknown" HEALTH="missing"
    [[ -n "$SNAPSHOT_ID" ]] && STATUS="Success" && HEALTH="ok"
    [[ $SNAPSHOT_TS -gt 0 && $AGE_SEC -gt $THRESHOLD_SEC ]] && HEALTH="stale"

    # Fetch stats if snapshot exists
    local RESTORE_SIZE="{}" RAW_DATA="{}"
    if [[ -n "$SNAPSHOT_ID" ]]; then
      RESTORE_SIZE=$(restic stats "$SNAPSHOT_ID" --json 2>/dev/null | jq 'del(.snapshots_count) | .total_restore_size = .total_size | .total_retore_file_count = .total_file_count | del(.total_size, .total_file_count)' || echo "{}")
      RAW_DATA=$(restic stats "$SNAPSHOT_ID" --json --mode raw-data 2>/dev/null | jq 'del(.snapshots_count) | .total_raw_data = .total_size | del(.total_size, .total_file_count)' || echo "{}")
    fi

    log_msg "$TAG: id=${SNAPSHOT_ID:-none} age=${AGE_SEC}s health=$HEALTH count=$SNAPSHOT_COUNT"

    # Build attributes in one jq call
    local ATTR=$(jq -nc \
      --arg status "$STATUS" --arg health "$HEALTH" --arg target "$TARGET" --arg tag "$TAG" \
      --arg snapshot_time "$SNAPSHOT_TIME" --arg snapshot_id "$SNAPSHOT_ID" \
      --argjson snapshots_count "$SNAPSHOT_COUNT" --argjson snapshot_ts "$SNAPSHOT_TS" --argjson age_seconds "$AGE_SEC" \
      --argjson restore "$RESTORE_SIZE" --argjson raw "$RAW_DATA" \
      '{status:$status, health:$health, target:$target, tag:$tag, snapshot_time:$snapshot_time, snapshot_id:$snapshot_id, snapshots_count:$snapshots_count, snapshot_ts:$snapshot_ts, age_seconds:$age_seconds} + $restore + $raw')

    # Publish
    local JOB_TOPIC="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"
    local FRIENDLY_TAG="${TAG//:/ }"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/config" -m "{\"name\":\"Restic backup ($TARGET / $FRIENDLY_TAG)\",\"state_topic\":\"$JOB_TOPIC/state\",\"value_template\":\"{{ value }}\",\"json_attributes_topic\":\"$JOB_TOPIC/attributes\",\"unique_id\":\"restic-$TOPIC_TAG-$TOPIC_TARGET\",\"device\":$DEVICE_JSON}"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/state" -m "$STATUS"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/attributes" -m "$ATTR"

    # Special case for backrest
    [[ "$TARGET" = "backrest" && "$TAG" = "plan:BojanoBackup" ]] && {
      local SINGLE_TOPIC="homeassistant/sensor/restic_backup_backrest_plan_bojanobackup"
      local COMBINED_ATTR=$(jq -sc add <<< "$ATTR $STATS_ATTR")
      $MOSQUITTO_PUB -r -t "$SINGLE_TOPIC/config" -m "{\"name\":\"Restic backup backrest plan BojanoBackup\",\"state_topic\":\"$SINGLE_TOPIC/state\",\"value_template\":\"{{ value }}\",\"json_attributes_topic\":\"$SINGLE_TOPIC/attributes\",\"unique_id\":\"restic-backup-backrest-plan-bojanobackup\",\"device\":$DEVICE_JSON}"
      $MOSQUITTO_PUB -r -t "$SINGLE_TOPIC/state" -m "$STATUS"
      $MOSQUITTO_PUB -r -t "$SINGLE_TOPIC/attributes" -m "$COMBINED_ATTR"
    }
  done < <(/etc/restic/util/list-tags.sh "$TARGET")
}

publish_stats
publish_snapshots
log_msg "Finished"
