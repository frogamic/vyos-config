#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MONGO_VER="9.0"
UNIFI_VER="latest"
TZ="Australia/Melbourne"
SELF_IP="192.168.88.1"
LAN_IF="br0"

MONGO_NAME="unifi-mongo"
MONGO_IMG="docker.io/mongo"
MONGO_DIR="/config/containers/${MONGO_NAME}"

MONGO_INITDB_ROOT_USERNAME="root"
MONGO_USER="unifi"
MONGO_DBNAME="unifi"
MONGO_AUTHSOURCE="admin"

UNIFI_NAME="unifi"
UNIFI_IMG="docker.io/linuxserver/unifi-network-application"
UNIFI_DIR="/config/containers/${UNIFI_NAME}"
UNIFI_MEM_LIMIT=1024
UNIFI_MEM_STARTUP=256
UNIFI_PUID=1002
UNIFI_PGID=100

NETWORK="unifi"
NETWORK_PARTIAL="172.31.254"
NETWORK_PREFIX="${NETWORK_PARTIAL}.248/29"
NETWORK_GATEWAY="${NETWORK_PARTIAL}.249"
MONGO_IP="${NETWORK_PARTIAL}.250"
UNIFI_IP="${NETWORK_PARTIAL}.251"

SET_CMDS=()

add_set() {
	SET_CMDS+=("set $*")
}

multi_set() {
	SET_CMDS+=("edit $1")
	shift
	local arg
	for arg in "$@"; do
		add_set "$arg"
	done
	SET_CMDS+=("top")
}

exec_cmds() {
	local cmdfile="$(mktemp)"

	echo "source /opt/vyatta/etc/functions/script-template" > "${cmdfile}"
	echo "configure" >> "${cmdfile}"

	local i=0
	while [ "$i" -lt "${#SET_CMDS[@]}" ]; do
		printf "%s\n" "${SET_CMDS[$i]}" >> "$cmdfile"
		i=$((i + 1))
	done

	echo "commit" >> "${cmdfile}"
	echo "exit" >> "${cmdfile}"

	chmod +x "${cmdfile}"
	if [ -z ${DRY_RUN+x} ]; then
		vbash "${cmdfile}"
	else
		echo vbash "${cmdfile}"
		cat "${cmdfile}"
	fi
	rm "${cmdfile}"

	SET_CMDS=()
}

container() {
	add_set "container name $*"
}

container_base() {
	local name="$1" image="$2"
	SET_CMDS+=("run add container image \"${image}\"")
	container "${name}" "image \"${image}\""
	container "${name}" "restart always"
}

container_vol() {
	local name="$1" vol="$2" src="$3" dst="$4" mode="${5:-rw}"
	container "${name}" "volume ${vol} source \"${src}\""
	container "${name}" "volume ${vol} destination \"${dst}\""
	container "${name}" "volume ${vol} mode ${mode}"
}

container_env() {
	local name="$1" var="$2" val="${!2:-$3}"
	container "${name}" "environment $var value \"${val}\""
}

container_port() {
	local name="$1" var="$2" val="${!2:-$3}"
	container "${name}" "environment $var value \"${val}\""
}

add_dest_nat() {
	local rule="$1" desc="$2" dest="$3" port="$4" proto="$5"
	multi_set "nat destination rule ${rule}" \
		"description \"${desc}\"" \
		"destination address ${SELF_IP}" \
		"destination port ${port}" \
		"inbound-interface name ${LAN_IF}" \
		"protocol ${proto}" \
		"translation address ${dest}" \
		"translation port ${port}"
}

persist_pass() {
	if [ -z ${DRY_RUN+x} ]; then
		local file="$1"
		if [ ! -f "${file}" ]; then
			openssl rand -base64 24 > "${file}"
		fi
		cat "${file}"
	else
		openssl rand -base64 24
	fi
}

################################################################################
#
#  Create persistent volume folders
#
################################################################################

if [ -z ${DRY_RUN+x} ]; then
	sudo mkdir -p "${UNIFI_DIR}"
	sudo mkdir -p "${MONGO_DIR}/db"
	sudo chown -R "${UNIFI_PUID}:${UNIFI_PGID}" "${UNIFI_DIR}"
	sudo chown -R "${UNIFI_PUID}:${UNIFI_PGID}" "${MONGO_DIR}"
	cp ./init-mongo.sh "${MONGO_DIR}"
fi

MONGO_PASS="$(persist_pass "${MONGO_DIR}/user.password")"
MONGO_INITDB_ROOT_PASSWORD="$(persist_pass "${MONGO_DIR}/root.password")"

multi_set container network "${NETWORK}" \
	"prefix \"${NETWORK_PREFIX}\"" \
	"gateway \"${NETWORK_GATEWAY}\""

################################################################################
#
#  Set up the mongodb container
#
################################################################################

container_base "${MONGO_NAME}" "${MONGO_IMG}:${MONGO_VER}"
container "${MONGO_NAME}" "network ${NETWORK} address ${MONGO_IP}"

container_vol "${MONGO_NAME}" db \
	"${MONGO_DIR}/db" \
	"/data/db"
container_vol "${MONGO_NAME}" initscript \
	"${MONGO_DIR}/init-mongo.sh" \
	"/docker-entrypoint-initdb.d/init-mongo.sh" "ro"

container_env "${MONGO_NAME}" MONGO_INITDB_ROOT_USERNAME
container_env "${MONGO_NAME}" MONGO_INITDB_ROOT_PASSWORD
container_env "${MONGO_NAME}" MONGO_USER
container_env "${MONGO_NAME}" MONGO_PASS
container_env "${MONGO_NAME}" MONGO_DBNAME
container_env "${MONGO_NAME}" MONGO_AUTHSOURCE

################################################################################
#
#  Set up the unifi-network-application container
#
################################################################################

container_base "${UNIFI_NAME}" "${UNIFI_IMG}:${UNIFI_VER}"
container "${UNIFI_NAME}" "network ${NETWORK} address ${UNIFI_IP}"

container_vol "${UNIFI_NAME}" config \
	"${UNIFI_DIR}" \
	"/config"

container "${UNIFI_NAME}" memory "${UNIFI_MEM_LIMIT}"

container_env "${UNIFI_NAME}" TZ
container_env "${UNIFI_NAME}" PUID $UNIFI_PUID
container_env "${UNIFI_NAME}" PGID $UNIFI_PGID
container_env "${UNIFI_NAME}" MONGO_USER
container_env "${UNIFI_NAME}" MONGO_PASS
container_env "${UNIFI_NAME}" MONGO_DBNAME
container_env "${UNIFI_NAME}" MONGO_AUTHSOURCE
container_env "${UNIFI_NAME}" MONGO_HOST "${MONGO_IP}"
container_env "${UNIFI_NAME}" MONGO_PORT 27017
container_env "${UNIFI_NAME}" MEM_LIMIT "${UNIFI_MEM_LIMIT}"
container_env "${UNIFI_NAME}" MEM_STARTUP "${UNIFI_MEM_STARTUP}"

################################################################################
#
#  Expose ports and enable dns
#
################################################################################

add_dest_nat 8000 "Unifi web admin" "${UNIFI_IP}" 8443 "tcp"
add_dest_nat 8001 "Unifi device communication" "${UNIFI_IP}" 8080 "tcp"
add_dest_nat 8002 "Unifi STUN" "${UNIFI_IP}" 3478 "udp"
add_dest_nat 8003 "Unifi AP discovery" "${UNIFI_IP}" 10001 "udp"


multi_set "firewall ipv4 input filter rule 15" \
	"action accept" \
	"inbound-interface name \"pod-${NETWORK}\"" \
	"protocol tcp_udp" \
	"destination address \"${NETWORK_GATEWAY}\"" \
	"destination port 53"

exec_cmds
