#!/usr/bin/env bash
# Publish restic stats + latest snapshot details for a target in one go.
# Usage: publish-restic-info.sh <target>

set -euo pipefail
JOB=$(basename "$0")
TARGET_INPUT=${1:-}
if [ -z "$TARGET_INPUT" ]; then
  echo "Usage: $0 <target>" >&2
  exit 1
fi

# Load target (pre.sh logs start and sets TARGET env); TAG intentionally empty.
TAG="" source /etc/restic/targets/includes/pre.sh "$TARGET_INPUT"

log_msg() {
  echo "[publish][$TARGET] $1" >&2
}

publish_stats() {
  TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
  RESTORE_SIZE_TOPIC="homeassistant/sensor/restic-stats-$TOPIC_TARGET-restore-size"
  RAW_DATA_TOPIC="homeassistant/sensor/restic-stats-$TOPIC_TARGET-raw-data"
  REPO_TOPIC="homeassistant/sensor/restic-repo-$TOPIC_TARGET-size"
  FILL_TOPIC="homeassistant/sensor/restic-repo-$TOPIC_TARGET-fill"

  log_msg "Publishing stats for $TARGET"
  log_msg "Restore topic: $RESTORE_SIZE_TOPIC"
  log_msg "Raw data topic: $RAW_DATA_TOPIC"
  log_msg "Repo topic: $REPO_TOPIC"
  log_msg "Fill topic: $FILL_TOPIC"

  $MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/config" -m "{ \"name\": \"restic stats $TARGET restore size\", \"state_topic\": \"$RESTORE_SIZE_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$RESTORE_SIZE_TOPIC/attributes\", \"unique_id\": \"restic-stats-$TOPIC_TARGET-restore-size\" }"
  $MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/config" -m "{ \"name\": \"restic stats $TARGET raw data\", \"state_topic\": \"$RAW_DATA_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$RAW_DATA_TOPIC/attributes\", \"unique_id\": \"restic-stats-$TOPIC_TARGET-raw-data\" }"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/config" -m "{ \"name\": \"Restic repo size ($TARGET)\", \"state_topic\": \"$REPO_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$REPO_TOPIC/attributes\", \"unique_id\": \"restic-repo-$TOPIC_TARGET-size\" }"
  $MOSQUITTO_PUB -r -t "$FILL_TOPIC/config" -m "{ \"name\": \"Restic repo fill ($TARGET)\", \"state_topic\": \"$FILL_TOPIC/state\", \"unit_of_measurement\": \"%\", \"device_class\": \"battery\", \"json_attributes_topic\": \"$FILL_TOPIC/attributes\", \"unique_id\": \"restic-repo-$TOPIC_TARGET-fill\" }"

  RESTORE_SIZE=$(restic stats --json)
  RAW_DATA=$(restic stats --json --mode raw-data)
  TOTAL_RESTORE_SIZE=$(echo $RESTORE_SIZE | jq ".total_size")
  TOTAL_RAW_DATA=$(echo $RAW_DATA | jq ".total_size")
  REPO_ATTR=$(echo $RESTORE_SIZE $RAW_DATA | jq -c -s 'add')

  FILL_PCT=""
  if [ -n "${DISK_SIZE:-}" ] && [ "$DISK_SIZE" -gt 0 ] 2>/dev/null; then
    FILL_PCT=$(python3 - <<EOF
import sys
try:
    disk=int(${DISK_SIZE})
    used=int(${TOTAL_RAW_DATA:-0})
    pct = round((used/disk)*100, 2)
    print(pct)
except Exception:
    sys.exit(1)
EOF
)
    log_msg "Repo fill: ${FILL_PCT}% of ${DISK_SIZE} bytes"
  else
    log_msg "Repo fill skipped (DISK_SIZE unset or invalid)"
  fi

  log_msg "Total restore size: $TOTAL_RESTORE_SIZE"
  log_msg "Total raw data (repo): $TOTAL_RAW_DATA"

  $MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/attributes" -m $RESTORE_SIZE
  $MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/attributes" -m $RAW_DATA
  $MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/state" -m $TOTAL_RESTORE_SIZE
  $MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/state" -m $TOTAL_RAW_DATA
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/attributes" -m "$REPO_ATTR"
  $MOSQUITTO_PUB -r -t "$REPO_TOPIC/state" -m "$TOTAL_RAW_DATA"
  if [ -n "$FILL_PCT" ]; then
    FILL_ATTR=$(echo "$REPO_ATTR" | jq -c --argjson fill ${FILL_PCT:-0} '. + {fill_percent:$fill}')
    $MOSQUITTO_PUB -r -t "$FILL_TOPIC/attributes" -m "$FILL_ATTR"
    $MOSQUITTO_PUB -r -t "$FILL_TOPIC/state" -m "$FILL_PCT"
  fi
}

publish_snapshots() {
  HEALTH_THRESHOLD_HOURS=${HEALTH_THRESHOLD_HOURS:-36}
  THRESHOLD_SEC=$((HEALTH_THRESHOLD_HOURS*3600))
  log_msg "Publishing snapshots (threshold ${HEALTH_THRESHOLD_HOURS}h)"

  for TAG in `/etc/restic/util/list-tags.sh $TARGET`; do
    log_msg "Processing tag: $TAG"
    TOPIC_TAG=$(sanitize_topic_component "$TAG")
    TOPIC_TARGET=$(sanitize_topic_component "$TARGET")

    SNAPSHOT_JSON=$(restic snapshots --latest 1 --tag "$TAG" --json 2>/dev/null || echo "[]")
    SNAPSHOT=$(echo "$SNAPSHOT_JSON" | jq -c '.[0] // {}')
    SNAPSHOT_ID=$(echo "$SNAPSHOT" | jq -r '.short_id // .id // ""')
    SNAPSHOT_TIME=$(echo "$SNAPSHOT" | jq -r '.time // ""')
    SNAPSHOT_TS=$(date -d "$SNAPSHOT_TIME" +%s 2>/dev/null || echo "0")
    SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
    SNAPSHOT_COUNT=$(echo "$SNAPSHOT_LIST" | jq 'length' 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    AGE_SEC=$((NOW_TS-SNAPSHOT_TS))

    RESTORE_SIZE=$(restic stats $SNAPSHOT_ID --json 2>/dev/null | jq 'del(.snapshots_count) | .["total_restore_size"] = .total_size | .["total_retore_file_count"] = .total_file_count | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")
    RAW_DATA=$(restic stats $SNAPSHOT_ID --json --mode raw-data 2>/dev/null | jq 'del(.snapshots_count) | .["total_raw_data"] = .total_size | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")

    STATUS="Unknown"
    if [ -n "$SNAPSHOT_ID" ]; then
      STATUS="Success"
    fi

    HEALTH="ok"
    if [ "$STATUS" = "Unknown" ]; then
      HEALTH="missing"
    elif [ $SNAPSHOT_TS -gt 0 ] && [ $AGE_SEC -gt $THRESHOLD_SEC ]; then
      HEALTH="stale"
    fi

    log_msg "snapshot_id=${SNAPSHOT_ID:-none} time=${SNAPSHOT_TIME:-n/a} age=${AGE_SEC}s health=$HEALTH status=$STATUS count=$SNAPSHOT_COUNT"

    BASE=$(jq -n \
      --arg status "$STATUS" \
      --arg health "$HEALTH" \
      --arg target "$TARGET" \
      --arg tag "$TAG" \
      --arg snapshot_time "$SNAPSHOT_TIME" \
      --arg snapshot_id "$SNAPSHOT_ID" \
      --argjson snapshots_count ${SNAPSHOT_COUNT:-0} \
      --argjson snapshot_ts ${SNAPSHOT_TS:-0} \
      --argjson age_seconds ${AGE_SEC:-0} \
      '{status:$status, health:$health, target:$target, tag:$tag, snapshot_time:$snapshot_time, snapshot_id:$snapshot_id, snapshots_count:$snapshots_count, snapshot_ts:$snapshot_ts, age_seconds:$age_seconds}')

    ATTR=$(echo "$BASE" "$RESTORE_SIZE" "$RAW_DATA" | jq -c -s 'add')

    JOB_TOPIC="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"
    FRIENDLY_TAG=$(echo "$TAG" | tr ':' ' ')
    log_msg "Publishing to $JOB_TOPIC (config/state/attributes)"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/config" -m "{ \"name\": \"Restic backup ($TARGET / $FRIENDLY_TAG)\", \"state_topic\": \"$JOB_TOPIC/state\", \"value_template\": \"{{ value }}\", \"json_attributes_topic\": \"$JOB_TOPIC/attributes\", \"unique_id\": \"restic-$TOPIC_TAG-$TOPIC_TARGET\" }"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/state" -m "$STATUS"
    $MOSQUITTO_PUB -r -t "$JOB_TOPIC/attributes" -m "$ATTR"
  done
}

publish_stats
publish_snapshots

log_msg "Finished publish"

# No post.sh to avoid changing backup state; this is a read-only publish.
