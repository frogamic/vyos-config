SELF_IP="192.168.88.1"
LAN_IF="br0"

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
	local rule="$1" desc="$2" dest="$3" port="$4" proto="$5" tport="${6:-$4}"
	multi_set "nat destination rule ${rule}" \
		"description \"${desc}\"" \
		"destination address ${SELF_IP}" \
		"destination port ${port}" \
		"inbound-interface name ${LAN_IF}" \
		"protocol ${proto}" \
		"translation address ${dest}" \
		"translation port ${tport}"
}

persist_pass() {
	if [ -z ${DRY_RUN+x} ]; then
		local file="$1"
		if [ ! -f "${file}" ]; then
			openssl rand -base64 24 | sudo tee "${file}"
			sudo chmod 600 "${file}"
		else
			sudo cat "${file}"
		fi
	else
		openssl rand -base64 24
	fi
}
