#!/usr/bin/env bash
JOB=$(basename "$0")

# Load target
source /etc/restic/targets/includes/pre.sh

log() {
	echo "[send-stats-info][$TARGET] $1" >&2
}

# Topics
TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
RESTORE_SIZE_TOPIC="homeassistant/sensor/restic-stats-$TOPIC_TARGET-restore-size"
RAW_DATA_TOPIC="homeassistant/sensor/restic-stats-$TOPIC_TARGET-raw-data"
REPO_TOPIC="homeassistant/sensor/restic-repo-$TOPIC_TARGET-size"

log "Starting stats refresh"
log "Restore topic: $RESTORE_SIZE_TOPIC"
log "Raw data topic: $RAW_DATA_TOPIC"
log "Repo topic: $REPO_TOPIC"

# Create restore size sensor
$MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/config" -m "{ \"name\": \"restic stats $TARGET restore size\", \"state_topic\": \"$RESTORE_SIZE_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$RESTORE_SIZE_TOPIC/attributes\", \"unique_id\": \"restic-stats-$TOPIC_TARGET-restore-size\" }"
# Create raw data sensor
$MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/config" -m "{ \"name\": \"restic stats $TARGET raw data\", \"state_topic\": \"$RAW_DATA_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$RAW_DATA_TOPIC/attributes\", \"unique_id\": \"restic-stats-$TOPIC_TARGET-raw-data\" }"
# Create repo size sensor (state = unique raw bytes stored)
$MOSQUITTO_PUB -r -t "$REPO_TOPIC/config" -m "{ \"name\": \"Restic repo size ($TARGET)\", \"state_topic\": \"$REPO_TOPIC/state\", \"value_template\": \"{{ value | filesizeformat() }}\", \"unit_of_measurement\": \"B\", \"json_attributes_topic\": \"$REPO_TOPIC/attributes\", \"unique_id\": \"restic-repo-$TOPIC_TARGET-size\" }"

# Send attributes
RESTORE_SIZE=$(restic stats --json)
RAW_DATA=$(restic stats --json --mode raw-data)
TOTAL_RESTORE_SIZE=$(echo $RESTORE_SIZE | jq ".total_size")
TOTAL_RAW_DATA=$(echo $RAW_DATA | jq ".total_size")
REPO_ATTR=$(echo $RESTORE_SIZE $RAW_DATA | jq -c -s 'add')

log "Total restore size: $TOTAL_RESTORE_SIZE"
log "Total raw data: $TOTAL_RAW_DATA"

$MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/attributes" -m $RESTORE_SIZE
$MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/attributes" -m $RAW_DATA
$MOSQUITTO_PUB -r -t "$RESTORE_SIZE_TOPIC/state" -m $TOTAL_RESTORE_SIZE
$MOSQUITTO_PUB -r -t "$RAW_DATA_TOPIC/state" -m $TOTAL_RAW_DATA
$MOSQUITTO_PUB -r -t "$REPO_TOPIC/attributes" -m "$REPO_ATTR"
$MOSQUITTO_PUB -r -t "$REPO_TOPIC/state" -m "$TOTAL_RAW_DATA"

log "Finished stats refresh"

#source /etc/restic/targets/includes/post.sh
