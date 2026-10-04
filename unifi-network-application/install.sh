#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MONGO_VER="9.0"
UNIFI_VER="latest"
TZ="Australia/Melbourne"

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

source ../common/common.sh

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
	cp ./mongo-init.sh "${MONGO_DIR}"
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
	"${MONGO_DIR}/mongo-init.sh" \
	"/docker-entrypoint-initdb.d/mongo-init.sh" "ro"

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
