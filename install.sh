#!/bin/bash

#export ARPANET2_ADDRESS=${ARPANET2_ADDRESS:=/var/run/arpanet2.address}

cmd-flocker-zfs-agent() {
	local IP="$1";
	local CONTROLIP="$2";

	if [[ -z "$CONTROLIP" ]]; then
		CONTROLIP="127.0.0.1";
	fi

	cat << EOF >> /etc/systemd/system/zfs-agent
[Unit]
Description=Flocker ZFS Agent

[Service]
TimeoutStartSec=0
ExecStart=sudo flocker-zfs agent $IP $CONTROLIP
EOF
}

cmd-flocker-control-service() {
	cat << EOF >> /etc/systemd/system/flocker-control
[Unit]
Description=Flocker Control Service

[Service]
TimeoutStartSec=0
ExecStart=sudo flocker-control -p 80
EOF
}

usage() {
cat <<EOF
Usage:
install.sh flocker-zfs-agent
install.sh flocker-control-service
install.sh help
EOF
	exit 1
}

main() {
	case "$1" in
	flocker-zfs-agent)  			shift; cmd-flocker-zfs-agent $@;;
	flocker-control-service)	shift; cmd-flocker-control-service $@;;
	*)                  			usage $@;;
	esac
}

# 

main "$@"
