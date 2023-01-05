#!/bin/bash

LOG_FILES_KEPT=5

FREEBOX_API_VERSION=v8
FREEBOX_APP_NAME="Freebox Server LAN Monitor"
FREEBOX_APP_ID="freebox_server_lan_monitor"
FREEBOX_APP_HOSTNAME="mafreebox.freebox.fr"
FREEBOX_API_BASE_URL="http://${FREEBOX_APP_HOSTNAME}/api/${FREEBOX_API_VERSION}"
FREEBOX_API_WS_BASE_URL="ws://${FREEBOX_APP_HOSTNAME}/api/${FREEBOX_API_VERSION}"

CURRENT_DIR=$(cd "$(dirname "$0")"; pwd)
PATH=$PATH:"${CURRENT_DIR}"
LOG_DIR="${CURRENT_DIR}/log"
LOG_FILE="${LOG_DIR}/freebox-lan-monitor.log"
FREEBOX_API_CONFIG_DIR="${CURRENT_DIR}/config"
FREEBOX_API_TMP_DIR="${CURRENT_DIR}/tmp"

ZIP=$(which zip) || \
	{ echo "$0 missing prereq zip. Fatal error."; exit 1; }
CURL=$(which curl) || \
  { echo "$0 missing prereq curl. Fatal error."; exit 1; }
# jq-1.5 is 10x faster than jq-1.6 !!!
JQ=$(which jq) || \
  { echo "$0 missing prereq jq. Fatal error."; exit 1; }
WEBSOCAT=$(which websocat) || \
  { echo "$0 missing prereq websocat. Fatal error."; exit 1; }
MOSQUITTO_PUB=$(which mosquitto_pub) || \
  { echo "WARNING: Missing optional prereq mosquitto_pub. Will not publish MQTT messages."; }

TIMESTAMP_COLOR='\033[0;37m'
NC='\033[0m' # No Color
ERROR_COLOR='\033[1;31m' #Red
WARN_COLOR='\033[1;33m' #Orange

main() {
	rm -rf "$FREEBOX_API_TMP_DIR"

	mkdir -p "$FREEBOX_API_CONFIG_DIR"
	mkdir -p "$FREEBOX_API_TMP_DIR"
	mkdir -p "$LOG_DIR"

	#TODO: systemctl stop is not trapped
	trap "quit" SIGINT SIGTERM

	exec &> >(tee -a -i "${LOG_FILE}")

	log "Starting freebox-lan-monitor"

	if [[ ! -z "$MOSQUITTO_PUB" ]]; then
		if [ -f "${FREEBOX_API_CONFIG_DIR}/mqtt_config.json" ]; then
			log "Loading MQTT config from file ${FREEBOX_API_CONFIG_DIR}/mqtt_config.json"
			MOSQUITTO_PUB_PARAMS=$(cat "${FREEBOX_API_CONFIG_DIR}/mqtt_config.json" | parseJSON ".mosquitto_pub_params")
			MQTT_TOPIC=$(cat "${FREEBOX_API_CONFIG_DIR}/mqtt_config.json" | parseJSON ".mqtt_topic")

			if [[ "$MOSQUITTO_PUB_PARAMS" == "null" || "$MQTT_TOPIC" == "null" ]]; then
				error "Incorrect MQTT config. Please review parameters."
				exit 1
			fi
		fi
	fi

	requestAuthorization
	login

	browseLAN

	if [[ ! -z $NOTIFY_SOCKET ]]; then
		systemd-notify --ready
	fi

	logArchiver &

	monitorLAN
}

requestAuthorization () {
	if [ ! -f ${FREEBOX_API_CONFIG_DIR}/app_params.json ] ; then
		echo { > ${FREEBOX_API_CONFIG_DIR}/app_params.json
		echo "\"app_id\": \"${FREEBOX_APP_ID}\"," >> ${FREEBOX_API_CONFIG_DIR}/app_params.json
		echo "\"app_name\": \"${FREEBOX_APP_NAME}\"," >> ${FREEBOX_API_CONFIG_DIR}/app_params.json
		echo "\"app_version\": \"0.0.1\"," >> ${FREEBOX_API_CONFIG_DIR}/app_params.json
		echo "\"device_name\": \"Shell\"" >> ${FREEBOX_API_CONFIG_DIR}/app_params.json
		echo } >> ${FREEBOX_API_CONFIG_DIR}/app_params.json
	fi

	if [ ! -f ${FREEBOX_API_CONFIG_DIR}/app_token.json ] ; then
		${CURL} -s -H "Content-Type: application/json" --data @${FREEBOX_API_CONFIG_DIR}/app_params.json ${FREEBOX_API_BASE_URL}/login/authorize/ > ${FREEBOX_API_CONFIG_DIR}/app_token.json
	fi

	appTokenSuccess=$(cat ${FREEBOX_API_CONFIG_DIR}/app_token.json | parseJSON ".success")
	if [[ "$appTokenSuccess" == "false" ]]; then
		appTokenErrorMsg=$(cat ${FREEBOX_API_CONFIG_DIR}/app_token.json | parseJSON ".msg")
		error "Invalid App Token: $appTokenErrorMsg"
		rm ${FREEBOX_API_CONFIG_DIR}/app_token.json
		exit 1
	fi

	appToken=($(cat ${FREEBOX_API_CONFIG_DIR}/app_token.json | parseJSON ".result.app_token, .result.track_id"))
	app_token=${appToken[0]}
	track_id=${appToken[1]}

	status=""
	if [ ! -f ${FREEBOX_API_TMP_DIR}/status.json ] ; then
		while [ "$status" != "granted" ]
		do
			${CURL} -s -H "Content-Type: application/json" ${FREEBOX_API_BASE_URL}/login/authorize/$track_id > ${FREEBOX_API_TMP_DIR}/status.json
			status=$(cat ${FREEBOX_API_TMP_DIR}/status.json | parseJSON ".result.status")			

			case $status in
				granted)
					log "App Token is valid and can be used to open a session"
				;;
				pending)
					warn "Pending App Token access grant. Please grant access from the Freebox front panel."
					sleep 5
				;;
				timeout)
					error "App access grant timeout. Aborting."
					exit 1
				;;
				unknown)
					error "The App Token is invalid or has been revoked. Aborting."
					exit 1
				;;
				denied)
					error "The user denied the authorization request. Aborting."
					exit 1
				;;
				*)
					error "Unexpected app authorization status error: $status. Aborting. Message: $(cat "${FREEBOX_API_TMP_DIR}/status.json")"
					exit 1
				;;
			esac
		done
	fi
}

login() {
	${CURL} -s -H "Content-Type: application/json" ${FREEBOX_API_BASE_URL}/login/ > ${FREEBOX_API_TMP_DIR}/login.json
	challenge=$(cat ${FREEBOX_API_TMP_DIR}/login.json | parseJSON ".result.challenge")
	password=$(echo -n $challenge | openssl sha1 -hmac $app_token | cut -d '=' -f2 | sed 's/ //g')

	echo { > ${FREEBOX_API_TMP_DIR}/credentials.json
	echo '"app_id": "'$FREEBOX_APP_ID'",' >> ${FREEBOX_API_TMP_DIR}/credentials.json
	echo '"password": "'$password'"' >> ${FREEBOX_API_TMP_DIR}/credentials.json
	echo } >> ${FREEBOX_API_TMP_DIR}/credentials.json

	${CURL} -s -H "Content-Type: application/json" --data @${FREEBOX_API_TMP_DIR}/credentials.json ${FREEBOX_API_BASE_URL}/login/session/ > ${FREEBOX_API_TMP_DIR}/session.json
	session=($(cat ${FREEBOX_API_TMP_DIR}/session.json | parseJSON ".success, .result.session_token"))
	success=${session[0]}
	session_token=${session[1]}

	if [[ "$success" == "true" ]]; then
		log "Freebox API login successful"
	else
		msg=$(cat ${FREEBOX_API_TMP_DIR}/session.json | parseJSON ".msg")
		error "Freebox API login failed: $msg"
		exit 1
	fi
}

browseLAN() {
	log "LAN devices browsing initiated"
	response=$(${CURL} -s -H "X-Fbx-App-Auth: ${session_token}" -H "Content-Type: application/json" ${FREEBOX_API_BASE_URL}/lan/browser/pub)

	echo ${response} | parseJSON ".result[]" | while read result; do

		primary_name=$(normalizePrimaryName "$(echo ${result} | parseJSON ".primary_name")")
		if [[ ! -z "$primary_name" ]]; then
			mqtt_msg="{\"success\": true, \"result\": ${result}, \"source\": \"lan\", \"action\": \"browse\"}"
			if [[ -f "${FREEBOX_API_CONFIG_DIR}/mqtt_config.json" ]]; then
				${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}" -m "${mqtt_msg}" &
			fi
		else
			warn "Ignoring empty primary_name. ${result}"
		fi
		
	done
	
	log "LAN devices browsing completed"
}

monitorLAN() {
	log "LAN devices monitoring registration in progress"
	#TODO: try reconnect:ws://....
	echo '{"action": "register", "events": ["lan_host_l3addr_reachable", "lan_host_l3addr_unreachable"]}' \
		| ${WEBSOCAT} --ping-timeout 120 --ping-interval 60 --text --no-close -H="X-Fbx-App-Auth: ${session_token}" ${FREEBOX_API_WS_BASE_URL}/ws/event \
		| while read notification; do
			#log "${notification}"
			processLANNotification "${notification}"
	done

	warn "LAN devices monitoring stopped. Relaunching."
	while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' --connect-timeout 5 ${FREEBOX_APP_HOSTNAME})" != "200" ]];
	do
			warn "Freebox endpoint could not be reached. Retrying ..."
			sleep 5
	done

	login
	monitorLAN
}

processLANNotification() {
	# https://stackoverflow.com/questions/43291389/using-jq-to-assign-multiple-output-variables
	read action success < <(echo $(echo $1 | parseJSON ".action, .success"))
	case $action in
		register)
			if [[ "$success" == "true" ]]; then
				log "LAN devices monitoring registration successful"
			else
				msg=$(echo $1 | parseJSON ".msg")
				error "LAN devices monitoring registration failed: ${msg}"
				exit 1
			fi
		;;
		notification)
			# primary_name set last on purpose as it may contain white space and break multiple variable parsing
			read event reachable primary_name < <(echo $(echo $1 | parseJSON ".event, .result.reachable, .result.primary_name"))
			access_point=$(echo $1 | parseJSON ".result.access_point")
			primary_name=$(normalizePrimaryName "${primary_name}")
			
			if [[ "$access_point" != "null" ]]; then
				access_point="true"
			else
				access_point="false"
			fi
			
			log "$primary_name:$event"

			if [[ ! -z "$primary_name" ]]; then
				if [[ -f "${FREEBOX_API_CONFIG_DIR}/mqtt_config.json" ]]; then
					${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}" -m "${1}" &
					${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}/last_event" -m "${event}" &
					${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}/last_event_timestamp" -m "$(date +"%Y-%m-%dT%H:%M:%S")" &
					${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}/reachable" -m "${reachable}" &
					${MOSQUITTO_PUB} ${MOSQUITTO_PUB_PARAMS} -t "${MQTT_TOPIC}/${primary_name}/access_point" -m "${access_point}" &
				fi
			else
				warn "Ignoring empty primary_name. ${1}"
			fi
		;;
		*)
			error "Unexpected action: '$action'. Message: $1"
		;;
	esac
}

normalizePrimaryName() {
	echo "${1}" | iconv -f utf8 -t ascii//TRANSLIT | tr A-Z a-z | tr [:blank:] _ | tr -cd [:alnum:]_ | sed 's/[^a-zA-Z 0-9 _-]//g'
}

logArchiver() {
	while true
	do
		numberSecondsUntilMidnight=$(($(date -d 'tomorrow 00:00:00' +%s) - $(date +%s)))
		sleep $numberSecondsUntilMidnight
		log "Archiving logs"
		${ZIP} -j "${LOG_FILE}_$(date +"%Y-%m-%d_%H%M%S").zip" "${LOG_FILE}" &> /dev/null
		# Clear log file content instead of deleting it - which messes with log process
		> "${LOG_FILE}"
		# Delete old archives
		ls -t "${LOG_DIR}/"*.zip | tail -n +$(($LOG_FILES_KEPT + 1)) | while read logArchive; do rm "${logArchive}"; done
	done
}

quit() {
	log "Stopping freebox-lan-monitor"
	exit
}

logout() {
	error "not implemented"
	#wget --header='X-Fbx-App-Auth: '$session_token ${FREEBOX_API_BASE_URL}/login/logout/ -O ${FREEBOX_API_TMP_DIR}/logout.json
}

parseJSON() {
	${JQ} -r -c "${1}"
}

log() {
	timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	>&2 echo -e "${TIMESTAMP_COLOR}[$timestamp]${NC} $1"
}

error() {
	timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	>&2 echo -e "${TIMESTAMP_COLOR}[$timestamp]${ERROR_COLOR} $1${NC}"
}

warn() {
	timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	>&2 echo -e "${TIMESTAMP_COLOR}[$timestamp]${WARN_COLOR} $1${NC}"
}

main "$@"; exit
