#!/usr/bin/env bash
JOB=`basename "$0"`

# Load target
source /etc/restic/targets/includes/pre.sh

log() {
	echo "[send-snapshot-info][$TARGET] $1" >&2
}

# Snapshots
HEALTH_THRESHOLD_HOURS=${HEALTH_THRESHOLD_HOURS:-36}
THRESHOLD_SEC=$((HEALTH_THRESHOLD_HOURS*3600))

log "Starting snapshot refresh (threshold ${HEALTH_THRESHOLD_HOURS}h)"

for TAG in `/etc/restic/util/list-tags.sh $TARGET`; do
	log "Processing tag: $TAG"
	TOPIC_TAG=$(sanitize_topic_component "$TAG")
	TOPIC_TARGET=$(sanitize_topic_component "$TARGET")

	# Get latest snapshot (best-effort)
	SNAPSHOT_JSON=$(restic snapshots --latest 1 --tag "$TAG" --json 2>/dev/null || echo "[]")
	SNAPSHOT=$(echo "$SNAPSHOT_JSON" | jq -c '.[0] // {}')
	SNAPSHOT_ID=$(echo "$SNAPSHOT" | jq -r '.short_id // .id // ""')
	SNAPSHOT_TIME=$(echo "$SNAPSHOT" | jq -r '.time // ""')
	SNAPSHOT_TS=$(date -d "$SNAPSHOT_TIME" +%s 2>/dev/null || echo "0")
	SNAPSHOT_LIST=$(restic snapshots --tag "$TAG" --json 2>/dev/null || echo "[]")
	SNAPSHOT_COUNT=$(echo "$SNAPSHOT_LIST" | jq 'length' 2>/dev/null || echo 0)
	if [ "${SNAPSHOT_DEBUG:-0}" != "0" ]; then
		log "snapshot list for tag [$TAG]: $(echo "$SNAPSHOT_LIST" | jq -r '.[].short_id // .[].id // .[].time // ""' | paste -sd',' -) (count=$SNAPSHOT_COUNT)"
	fi
	NOW_TS=$(date +%s)
	AGE_SEC=$((NOW_TS-SNAPSHOT_TS))

	RESTORE_SIZE=$(restic stats $SNAPSHOT_ID --json 2>/dev/null | jq 'del(.snapshots_count) | . ["total_restore_size"] = .total_size | .["total_retore_file_count"] = .total_file_count | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")
	RAW_DATA=$(restic stats $SNAPSHOT_ID --json --mode raw-data 2>/dev/null | jq 'del(.snapshots_count) | . ["total_raw_data"] = .total_size | del(.total_size, .total_file_count)' 2>/dev/null || echo "{}")

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

	log "snapshot_id=${SNAPSHOT_ID:-none} time=${SNAPSHOT_TIME:-n/a} age=${AGE_SEC}s health=$HEALTH status=$STATUS"

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
	log "Publishing to $JOB_TOPIC (config/state/attributes)"
	$MOSQUITTO_PUB -r -t "$JOB_TOPIC/config" -m "{ \"name\": \"Restic backup ($TARGET / $FRIENDLY_TAG)\", \"state_topic\": \"$JOB_TOPIC/state\", \"value_template\": \"{{ value }}\", \"json_attributes_topic\": \"$JOB_TOPIC/attributes\", \"unique_id\": \"restic-$TOPIC_TAG-$TOPIC_TARGET\" }"
	$MOSQUITTO_PUB -r -t "$JOB_TOPIC/state" -m "$STATUS"
	$MOSQUITTO_PUB -r -t "$JOB_TOPIC/attributes" -m "$ATTR"
done

log "Finished snapshot refresh"

#source /etc/restic/targets/includes/post.sh
