# Ensure TAG is defined (scripts without TAG will skip job topics)
TAG=${TAG:-}

# Common
source /etc/restic/targets/includes/common.sh

# Choose target
if [ -f "/etc/restic/targets/$1_env.sh" ]; then
	source "/etc/restic/targets/$1_env.sh"
	export TARGET=$1
else
	echo "$1 backup target not found"
	exit 1
fi

# Export timing for downstream scripts
export START_TS=$(date +%s)
export START_TIME_ISO=$(date -Iseconds)

# MQTT sensor wiring
HEALTH_THRESHOLD_HOURS=${HEALTH_THRESHOLD_HOURS:-36}
export HEALTH_THRESHOLD_HOURS

if [ -n "$TAG" ]; then
	TOPIC_TAG=$(sanitize_topic_component "$TAG")
	TOPIC_TARGET=$(sanitize_topic_component "$TARGET")
	export JOB_TOPIC="homeassistant/sensor/restic-$TOPIC_TAG-$TOPIC_TARGET"
	# Create/refresh HA discovery config and mark run as started
	FRIENDLY_TAG=$(echo "$TAG" | tr ':' ' ')
	$MOSQUITTO_PUB -r -t "$JOB_TOPIC/config" -m "{ \"name\": \"Restic backup ($TARGET / $FRIENDLY_TAG)\", \"state_topic\": \"$JOB_TOPIC/state\", \"value_template\": \"{{ value }}\", \"json_attributes_topic\": \"$JOB_TOPIC/attributes\", \"unique_id\": \"restic-$TOPIC_TAG-$TOPIC_TARGET\" }"
	$MOSQUITTO_PUB -t "$JOB_TOPIC/state" -m "Running"
fi

$MOSQUITTO_PUB -t /restic/backup -m $JOB,$TARGET,starting
