#!/bin/bash

#export ARPANET2_ADDRESS=${ARPANET2_ADDRESS:=/var/run/arpanet2.address}

cmd-flocker-zfs-agent() {
	cat << EOF >> /etc/rc.d/rc.local

EOF
}

cmd-flocker-control-service() {
	cat << EOF >> /etc/rc.d/rc.local

EOF
}

cmd-setup-file() {
	cat << EOF > /etc/rc.d/rc.local
#!/bin/bash

EOF
}
usage() {
cat <<EOF
Usage:
install.sh flocker-zfs-agent
install.sh flocker-control
install.sh help
EOF
	exit 1
}

main() {
	cmd-setup-file

	if [[ "$1" == "node1" ]]; then

	fi
}

main "$@"
