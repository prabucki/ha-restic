source /etc/restic/targets/passwords/mqtt.sh

# MQTT defaults (tunable via env)
MQTT_CLIENT_ID=${MQTT_CLIENT_ID:-restic-${HOSTNAME:-host}-$$_$RANDOM}
MQTT_QOS=${MQTT_QOS:-1}
MQTT_DEBUG=${MQTT_DEBUG:-0}
MQTT_PORT=${MQTT_PORT:-}
MOSQUITTO_DEBUG_FLAG=""
if [ "$MQTT_DEBUG" != "0" ]; then
	MOSQUITTO_DEBUG_FLAG="-d"
fi

MOSQUITTO_PUB_BIN="/usr/bin/mosquitto_pub"

if ! command -v "$MOSQUITTO_PUB_BIN" >/dev/null 2>&1; then
	echo "[mqtt] mosquitto_pub not found at $MOSQUITTO_PUB_BIN" >&2
fi

# Sanitize topic components to avoid broker/HA quirks (replace anything non-alnum/[_-])
sanitize_topic_component() {
	echo "$1" | sed 's/[^A-Za-z0-9_-]/_/g'
}

# Helper to log (without secrets) and publish
mqtt_publish() {
	# Accept normal mosquitto_pub args; log topic if present
	local args=()
	local topic=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-t)
				topic=$2
				args+=("$1" "$2")
				shift 2
				;;
			*)
				args+=("$1")
				shift
				;;
		esac
	done
	echo "[mqtt][$MQTT_CLIENT_ID] pub topic=${topic:-unknown} qos=$MQTT_QOS host=$MQTT_HOST port=${MQTT_PORT:-default}" >&2

	# shellcheck disable=SC2086
	$MOSQUITTO_PUB_BIN -i "$MQTT_CLIENT_ID" -q "$MQTT_QOS" $MOSQUITTO_DEBUG_FLAG ${MQTT_PORT:+-p "$MQTT_PORT"} -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" "${args[@]}"
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "[mqtt][$MQTT_CLIENT_ID] publish failed (rc=$rc) topic=${topic:-unknown}" >&2
	fi
	return $rc
}

# Exposed command used by scripts
MOSQUITTO_PUB=mqtt_publish
