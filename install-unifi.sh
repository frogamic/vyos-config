#!/bin/vbash

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

SET_CMDS=()

add_set() {
	SET_CMDS+=("set $*")
}

exec_cmds() {
	local cmdfile="$(mktemp)"

	echo "source /opt/vyatta/etc/functions/script-template" > "${cmdfile}"
	echo "configure" >> "${cmdfile}"
	i=0
	while [ "$i" -lt "${#SET_CMDS[@]}" ]; do
		printf "%s\n" "${SET_CMDS[$i]}" >> "$cmdfile"
		i=$((i + 1))
	done
	echo "commit" >> "${cmdfile}"

	chmod +x "${cmdfile}"
	vbash "${cmdfile}"

	SET_CMDS=()
}

container() {
	add_set "container name $*"
}

container_base() {
	local name="$1" image="$2"
	container "${name}" "image \"${image}\""
	container "${name}" "restart always"
	container "${name}" "network ${NETWORK}"
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
	add_set "nat destination rule ${rule} description \"${desc}\""
	add_set "nat destination rule ${rule} destination address ${SELF_IP}"
	add_set "nat destination rule ${rule} destination port ${port}"
	add_set "nat destination rule ${rule} inbound-interface name ${LAN_IF}"
	add_set "nat destination rule ${rule} protocol ${proto}"
	add_set "nat destination rule ${rule} translation address ${dest}"
	add_set "nat destination rule ${rule} translation port ${port}"
}

persist_pass() {
	local file="$1"
	if [ ! -f "${file}" ]; then
		openssl rand -base64 24 > "${file}"
	fi
	cat "${file}"
}

################################################################################
#
#  Create persistent volume folders
#
################################################################################

mkdir -p "${UNIFI_DIR}"
mkdir -p "${MONGO_DIR}/db"
cp ./init-mongo.sh "${MONGO_DIR}"

MONGO_PASS="$(persist_pass "${MONGO_DIR}/user.password")"
MONGO_INITDB_ROOT_PASSWORD="$(persist_pass "${MONGO_DIR}/root.password")"

add_set container network "${NETWORK}"

################################################################################
#
#  Set up the mongodb container
#
################################################################################

container_base "${MONGO_NAME}" "${MONGO_IMG}:${MONGO_VER}"

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

container_vol "${UNIFI_NAME}" config \
	"${UNIFI_DIR}" \
	"/config"

container "${UNIFI_NAME}" memory "${UNIFI_MEM_LIMIT}"

container_env "${UNIFI_NAME}" TZ
container_env "${UNIFI_NAME}" PUID UNIFI_PUID
container_env "${UNIFI_NAME}" PGID UNIFI_PGID
container_env "${UNIFI_NAME}" MONGO_USER
container_env "${UNIFI_NAME}" MONGO_PASS
container_env "${UNIFI_NAME}" MONGO_DBNAME
container_env "${UNIFI_NAME}" MONGO_AUTHSOURCE
container_env "${UNIFI_NAME}" MONGO_HOST "${MONGO_NAME}"
container_env "${UNIFI_NAME}" MONGO_PORT 27017
container_env "${UNIFI_NAME}" MEM_LIMIT "${UNIFI_MEM_LIMIT}"
container_env "${UNIFI_NAME}" MEM_STARTUP "${UNIFI_MEM_STARTUP}"

exec_cmds

################################################################################
#
#  Expose ports
#
################################################################################

UNIFI_IP="$(sudo podman inspect "${UNIFI_NAME}" | jq ".[0].NetworkSettings.Networks.${NETWORK}.IPAddress" -r)"
add_dest_nat 8000 "Unifi web admin" "${UNIFI_IP}" 8443 "tcp"
add_dest_nat 8001 "Unifi device communication" "${UNIFI_IP}" 8080 "tcp"
add_dest_nat 8002 "Unifi STUN" "${UNIFI_IP}" 3478 "udp"
add_dest_nat 8003 "Unifi AP discovery" "${UNIFI_IP}" 10001 "udp"

exec_cmds
