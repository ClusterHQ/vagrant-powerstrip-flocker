#!/bin/bash

export FLOCKER_CONTROL_PORT=${FLOCKER_CONTROL_PORT:=80}

# on subsequent vagrant ups - vagrant has not mounted /vagrant/install.sh
# so we copy it into place
cmd-copy-vagrant-dir() {
  cp -r /vagrant /srv/vagrant
}

# extract the current zfs-agent uuid from the volume.json - sed sed sed!
cmd-get-flocker-uuid() {
  if [[ ! -f /etc/flocker/volume.json ]]; then
    >&2 echo "/etc/flocker/volume.json NOT FOUND";
    exit 1;
  fi
  cat /etc/flocker/volume.json | sed 's/.*"uuid": "//' | sed 's/"}//'
}

# wait until the named file exists
cmd-wait-for-file() {
  while [ ! -f $1 ]
  do
    echo "wait for file $1" && sleep 1
  done
}

# configure docker to listen on a different unix socket and make sure selinux is not turned on
cmd-configure-docker() {
  /usr/sbin/setenforce 0

  echo "configuring docker to listen on unix:///var/run/docker.real.sock";

  # docker itself listens on docker.real.sock and powerstrip listens on docker.sock
  cat << EOF > /etc/sysconfig/docker-network
DOCKER_NETWORK_OPTIONS=-H unix:///var/run/docker.real.sock
EOF

  # the key here is removing the selinux=yes option from docker
  cat << EOF > /etc/sysconfig/docker 
OPTIONS=''
DOCKER_CERT_PATH=/etc/docker
TMPDIR=/var/tmp
EOF

  systemctl restart docker
  rm -f /var/run/docker.sock
}

# create a link for the named systemd unit so it starts at boot
cmd-link-systemd-target() {
	ln -sf /etc/systemd/system/$1.service /etc/systemd/system/multi-user.target.wants/$1.service
}

# stop and remove a named container
cmd-docker-remove() {
  echo "remove container $1";
	DOCKER_HOST="unix:///var/run/docker.real.sock" /usr/bin/docker stop $1 2>/dev/null || true
	DOCKER_HOST="unix:///var/run/docker.real.sock" /usr/bin/docker rm $1 2>/dev/null || true
}

# docker pull a named container
cmd-docker-pull() {
  echo "pull image $1";
	DOCKER_HOST="unix:///var/run/docker.real.sock" /usr/bin/docker pull $1
}

# write a systemd unit for the powerstrip-flocker adapter
cmd-configure-adapter() {
  local IP="$1";
  local CONTROLIP="$2";
  echo "configure powerstrip adapter - $1 $2";
  cat << EOF > /etc/systemd/system/powerstrip-flocker.service
[Unit]
Description=Powerstrip Flocker Adapter
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/bash /srv/vagrant/install.sh start-adapter $IP $CONTROLIP
ExecStop=/usr/bin/bash /srv/vagrant/install.sh docker-remove powerstrip-flocker

[Install]
WantedBy=multi-user.target
EOF

	cmd-link-systemd-target powerstrip-flocker
}

# the actual boot command for the powerstrip adapter
# we run without -d so that systemd can manage the process properly
cmd-start-adapter() {
	cmd-docker-remove powerstrip-flocker
  local IP="$1";
  local CONTROLIP="$2";
  local HOSTID=$(cmd-get-flocker-uuid)
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name powerstrip-flocker \
    --expose 80 \
    -e "MY_NETWORK_IDENTITY=$IP" \
    -e "FLOCKER_CONTROL_SERVICE_BASE_URL=http://$CONTROLIP:80/v1" \
    -e "MY_HOST_UUID=$HOSTID" \
    clusterhq/powerstrip-flocker:latest
}

# write the systemd unit file for powerstrip itself
cmd-configure-powerstrip() {
  echo "configure powerstrip";
  cat << EOF > /etc/systemd/system/powerstrip.service
[Unit]
Description=Powerstrip Server
After=powerstrip-flocker.service
Requires=powerstrip-flocker.service

[Service]
ExecStart=/usr/bin/bash /srv/vagrant/install.sh start-powerstrip
ExecStop=/usr/bin/bash /srv/vagrant/install.sh docker-remove powerstrip

[Install]
WantedBy=multi-user.target
EOF

	cmd-link-systemd-target powerstrip
}

# the boot step for the powerstrip container - start without -d so systemd can manage the process
cmd-start-powerstrip() {
	rm -f /var/run/docker.sock
	cmd-docker-remove powerstrip
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name powerstrip \
    -v /var/run:/host-var-run \
    -v /etc/powerstrip-demo/adapters.yml:/etc/powerstrip/adapters.yml \
    --link powerstrip-flocker:flocker \
    clusterhq/powerstrip:unix-socket
  sleep 5
  chgrp vagrant /var/run/docker.sock
}

# write out adapters.yml for powerstrip
cmd-powerstrip-config() {
  echo "write /etc/powerstrip-demo/adapters.yml";
  mkdir -p /etc/powerstrip-demo
  cat << EOF >> /etc/powerstrip-demo/adapters.yml
version: 1
endpoints:
  "POST /*/containers/create":
    pre: [flocker]
adapters:
  flocker: http://flocker/flocker-adapter
EOF
}

# write systemd unit file for the zfs agent
cmd-flocker-zfs-agent() {
  echo "configure flocker-zfs-agent $@";
  cat << EOF > /etc/systemd/system/flocker-zfs-agent.service
[Unit]
Description=Flocker ZFS Agent

[Service]
TimeoutStartSec=0
ExecStart=/usr/bin/bash /srv/vagrant/install.sh block-start-flocker-zfs-agent $@

[Install]
WantedBy=multi-user.target
EOF

	cmd-link-systemd-target flocker-zfs-agent
}

# runner for the zfs agent
# we wait for there to be a docker socket by waiting for docker info
# we then wait for there to be a powerstrip container
cmd-block-start-flocker-zfs-agent() {
  local IP="$1";
  local CONTROLIP="$2";

  if [[ -z "$CONTROLIP" ]]; then
    CONTROLIP="127.0.0.1";
  fi

  echo "wait for docker socket before starting flocker-zfs-agent";

  while ! docker info; do echo "waiting for /var/run/docker.sock" && sleep 1; done;
  /opt/flocker/bin/flocker-zfs-agent $IP $CONTROLIP
}

# write a systemd file for the control service
cmd-flocker-control-service() {

  echo "configure flocker-control-service";

  cat << EOF > /etc/systemd/system/flocker-control-service.service
[Unit]
Description=Flocker Control Service

[Service]
TimeoutStartSec=0
ExecStart=/opt/flocker/bin/flocker-control -p $FLOCKER_CONTROL_PORT

[Install]
WantedBy=multi-user.target
EOF

	cmd-link-systemd-target flocker-control-service
}

# generic controller for the powerstrip containers
cmd-powerstrip() {
	# write adapters.yml
  cmd-powerstrip-config

  # write unit files for powerstrip-flocker and powerstrip
  cmd-configure-adapter $@
  cmd-configure-powerstrip

  # pull the images first
  cmd-docker-pull ubuntu:latest
	cmd-docker-pull clusterhq/powerstrip-flocker:latest
	cmd-docker-pull clusterhq/powerstrip:unix-socket

  # kick off systemctl
  systemctl daemon-reload
  systemctl enable powerstrip-flocker.service
  systemctl enable powerstrip.service
  systemctl start powerstrip-flocker.service
  systemctl start powerstrip.service
}

# kick off the zfs-agent so it writes /etc/flocker/volume.json
# then kill it before starting the powerstrip-adapter (which requires the file)
cmd-setup-zfs-agent() {
  cmd-flocker-zfs-agent $@

  # we need to start the zfs service so we have /etc/flocker/volume.json
  systemctl daemon-reload
  systemctl start flocker-zfs-agent.service
  cmd-wait-for-file /etc/flocker/volume.json
  systemctl stop flocker-zfs-agent.service

  # setup docker on /var/run/docker.real.sock
  cmd-configure-docker

  
}

# master <OWN_IP> <CONTROL_IP>
cmd-master() {
  cmd-copy-vagrant-dir
  # write unit files for both services
  cmd-flocker-control-service
  cmd-setup-zfs-agent $@
  cmd-powerstrip $@

  # kick off systemctl
  systemctl daemon-reload
  systemctl enable flocker-control-service.service
  systemctl enable flocker-zfs-agent.service
  systemctl start flocker-control-service.service
  systemctl start flocker-zfs-agent.service
  
}

# minion <OWN_IP> <CONTROL_IP>
cmd-minion() {
  cmd-copy-vagrant-dir
  cmd-setup-zfs-agent $@
  cmd-powerstrip $@

  systemctl daemon-reload
  systemctl enable flocker-zfs-agent.service
  systemctl start flocker-zfs-agent.service
  
}

usage() {
cat <<EOF
Usage:
install.sh master
install.sh minion
install.sh flocker-zfs-agent
install.sh flocker-control-service
install.sh get-flocker-uuid
install.sh configure-docker
install.sh configure-powerstrip
install.sh configure-adapter
install.sh start-adapter
install.sh start-powerstrip
install.sh powerstrip-config
install.sh help
EOF
  exit 1
}

main() {
  case "$1" in
  master)                   shift; cmd-master $@;;
  minion)                   shift; cmd-minion $@;;
  flocker-zfs-agent)        shift; cmd-flocker-zfs-agent $@;;
  block-start-flocker-zfs-agent) shift; cmd-block-start-flocker-zfs-agent $@;;
  flocker-control-service)  shift; cmd-flocker-control-service $@;;
  get-flocker-uuid)         shift; cmd-get-flocker-uuid $@;;
  configure-docker)         shift; cmd-configure-docker $@;;
  configure-powerstrip)     shift; cmd-configure-powerstrip $@;;
  configure-adapter)        shift; cmd-configure-adapter $@;;
  start-adapter)            shift; cmd-start-adapter $@;;
  start-powerstrip)         shift; cmd-start-powerstrip $@;;
  powerstrip-config)        shift; cmd-powerstrip-config $@;;
	docker-remove)            shift; cmd-docker-remove $@;;
  *)                        usage $@;;
  esac
}

# 

main "$@"
