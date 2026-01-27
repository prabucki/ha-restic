RESTIC_RETURN=$?

# Common
source /etc/restic/targets/includes/common.sh

# Timing
END_TS=$(date +%s)
END_TIME_ISO=$(date -Iseconds)
DURATION=$((END_TS-START_TS))

# Snapshot + stats (best-effort; avoid breaking publish on errors)
LAST_SNAPSHOT=$(restic snapshots --latest 1 --tag "$TAG" --json | jq -c '.[0]' 2>/dev/null || echo "{}")
SNAPSHOT_ID=$(echo "$LAST_SNAPSHOT" | jq -r '.short_id // ""')
SNAPSHOT_TIME=$(echo "$LAST_SNAPSHOT" | jq -r '.time // ""')

RESTORE_SIZE=$(restic stats $SNAPSHOT_ID --json 2>/dev/null | jq '."total_restore_size" = .total_size | ."total_restore_file_count" = .total_file_count | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")
RAW_DATA=$(restic stats $SNAPSHOT_ID --json --mode raw-data 2>/dev/null | jq '."total_raw_data" = .total_size | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")

STATUS="Success"
if [ $RESTIC_RETURN -ne 0 ]; then
	STATUS="Failure"
fi

NOW_TS=$(date +%s)
AGE_SEC=$((NOW_TS-START_TS))
THRESHOLD_SEC=$((HEALTH_THRESHOLD_HOURS*3600))
HEALTH="ok"
if [ "$STATUS" != "Success" ]; then
	HEALTH="failed"
elif [ $AGE_SEC -gt $THRESHOLD_SEC ]; then
	HEALTH="stale"
fi

BASE=$(jq -n \
	--arg status "$STATUS" \
	--arg health "$HEALTH" \
	--arg target "$TARGET" \
	--arg tag "$TAG" \
	--arg start_iso "$START_TIME_ISO" \
	--arg end_iso "$END_TIME_ISO" \
	--arg snapshot_time "$SNAPSHOT_TIME" \
	--arg snapshot_id "$SNAPSHOT_ID" \
	--argjson duration $DURATION \
	--argjson start_ts $START_TS \
	--argjson end_ts $END_TS \
	'{status:$status, health:$health, target:$target, tag:$tag, last_start:$start_iso, last_end:$end_iso, duration_seconds:$duration, snapshot_time:$snapshot_time, snapshot_id:$snapshot_id, start_ts:$start_ts, end_ts:$end_ts}')

ATTRIBUTES=$(echo "$BASE" "$RESTORE_SIZE" "$RAW_DATA" | jq -c -s 'add')

# Notify Home Assistant
$MOSQUITTO_PUB -t /restic/backup -m $JOB,$TARGET,finished,$RESTIC_RETURN
$MOSQUITTO_PUB -t "$JOB_TOPIC/state" -m "$STATUS"
$MOSQUITTO_PUB -t "$JOB_TOPIC/attributes" -m "$ATTRIBUTES"
