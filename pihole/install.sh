#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

DNSCRYPT_VER="latest"
PIHOLE_VER="latest"
TZ="Australia/Melbourne"

DNSCRYPT_NAME="pihole-dnscrypt"
DNSCRYPT_IMG="docker.io/klutchell/dnscrypt-proxy"
DNSCRYPT_DIR="/config/containers/${DNSCRYPT_NAME}"
DNSCRYPT_UID=1053

PIHOLE_NAME="pihole"
PIHOLE_IMG="docker.io/pihole/pihole"
PIHOLE_DIR="/config/containers/${PIHOLE_NAME}"

NETWORK="pihole"
NETWORK_PARTIAL="172.31.254"
NETWORK_PREFIX="${NETWORK_PARTIAL}.240/29"
NETWORK_GATEWAY="${NETWORK_PARTIAL}.241"
DNSCRYPT_IP="${NETWORK_PARTIAL}.242"
PIHOLE_IP="${NETWORK_PARTIAL}.243"

source ../common/common.sh

################################################################################
#
#  Create persistent volume folders
#
################################################################################

if [ -z ${DRY_RUN+x} ]; then
	sudo mkdir -p "${DNSCRYPT_DIR}"
	sudo mkdir -p "${PIHOLE_DIR}/etc"
	sudo cp ./dnscrypt-proxy.toml "${DNSCRYPT_DIR}/"
	sudo chown -R "${DNSCRYPT_UID}:${DNSCRYPT_UID}" "${DNSCRYPT_DIR}"
fi

FTLCONF_webserver_api_password="$(persist_pass "${PIHOLE_DIR}/ftl.password")"
FTLCONF_dns_listeningMode="ALL"
FTLCONF_dns_upstreams="${DNSCRYPT_IP}"

multi_set "container network \"${NETWORK}\"" \
	"prefix \"${NETWORK_PREFIX}\"" \
	"gateway \"${NETWORK_GATEWAY}\""

################################################################################
#
#  Set up the dnscrypt-proxy container
#
################################################################################

container_base "${DNSCRYPT_NAME}" "${DNSCRYPT_IMG}:${DNSCRYPT_VER}"
container "${DNSCRYPT_NAME}" network "${NETWORK}" address "${DNSCRYPT_IP}"
container "${DNSCRYPT_NAME}" sysctl parameter net.ipv4.ip_unprivileged_port_start value 53
container "${DNSCRYPT_NAME}" uid "${DNSCRYPT_UID}"
container "${DNSCRYPT_NAME}" gid "${DNSCRYPT_UID}"

container_vol "${DNSCRYPT_NAME}" config \
	"${DNSCRYPT_DIR}" \
	"/config"

################################################################################
#
#  Set up the unifi-network-application container
#
################################################################################

container_base "${PIHOLE_NAME}" "${PIHOLE_IMG}:${PIHOLE_VER}"
container "${PIHOLE_NAME}" "network ${NETWORK} address ${PIHOLE_IP}"
container "${PIHOLE_NAME}" "capability net-bind-service"
container "${PIHOLE_NAME}" "capability sys-nice"

container_vol "${PIHOLE_NAME}" etc \
	"${PIHOLE_DIR}/etc" \
	"/etc/pihole"

container_env "${PIHOLE_NAME}" TZ
container_env "${PIHOLE_NAME}" FTLCONF_webserver_api_password
container_env "${PIHOLE_NAME}" FTLCONF_dns_listeningMode
container_env "${PIHOLE_NAME}" FTLCONF_dns_upstreams

################################################################################
#
#  Expose ports and enable dns
#
################################################################################

add_dest_nat 8050 "pihole http" "${PIHOLE_IP}" 80 "tcp"
add_dest_nat 8051 "pihole dns listener" "${PIHOLE_IP}" 53 "tcp_udp"
add_dest_nat 8052 "pihole https" "${PIHOLE_IP}" 443 "udp"

multi_set "firewall ipv4 input filter rule 53" \
	"action accept" \
	"inbound-interface name \"pod-${NETWORK}\"" \
	"protocol tcp_udp" \
	"destination address \"${NETWORK_GATEWAY}\"" \
	"destination port 53"
multi_set "firewall ipv4 input filter rule 54" \
	"action accept" \
	"inbound-interface name \"lo\"" \
	"protocol tcp_udp" \
	"destination address \"${DNSCRYPT_IP}\"" \
	"destination port 53"
multi_set "firewall ipv4 input filter rule 55" \
	"action accept" \
	"inbound-interface name \"lo\"" \
	"protocol tcp_udp" \
	"destination address \"${PIHOLE_IP}\"" \
	"destination port 53"

add_set system name-server "${PIHOLE_IP}"
add_set system name-server "${DNSCRYPT_IP}"

exec_cmds
