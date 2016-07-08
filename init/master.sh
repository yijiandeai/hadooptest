#!/bin/bash

# Copyright 2015 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A script to setup the k8s master in docker containers.
# Authors @wizard_cxy @resouer
# use docker.io private images

set -e

# Make sure docker daemon is running
if ( ! ps -ef |grep `cat /var/run/docker.pid` | grep -v 'grep' &> /dev/null); then
    echo "Docker is not running on this machine!"
    exit 1
fi

# Make sure k8s version env is properly set
K8S_VERSION=${K8S_VERSION:-"1.2.0"}
ETCD_VERSION=${ETCD_VERSION:-"2.2.1"}
FLANNEL_VERSION=${FLANNEL_VERSION:-"0.5.5"}
FLANNEL_IPMASQ=${FLANNEL_IPMASQ:-"true"}
FLANNEL_IFACE=${FLANNEL_IFACE:-"eth1"}
ARCH=${ARCH:-"amd64"}
FLANNEL_DOCKER_SOCK=${FLANNEL_DOCKER_SOCK:-"unix:///var/run/early-docker.sock"}
BOOTSTRAP_FLANNEL=${BOOTSTRAP_FLANNEL:-"true"}

# Run as root
if [ "$(id -u)" != "0" ]; then
    echo >&2 "Please run as root"
    exit 1
fi

# Make sure master ip is properly set
if [ -z ${MASTER_IP} ]; then
    MASTER_IP=$(hostname -i | awk '{print $1}')
fi

echo "K8S_VERSION is set to: ${K8S_VERSION}"
echo "ETCD_VERSION is set to: ${ETCD_VERSION}"
echo "FLANNEL_VERSION is set to: ${FLANNEL_VERSION}"
echo "FLANNEL_IFACE is set to: ${FLANNEL_IFACE}"
echo "FLANNEL_IPMASQ is set to: ${FLANNEL_IPMASQ}"
echo "MASTER_IP is set to: ${MASTER_IP}"
echo "ARCH is set to: ${ARCH}"

# Check if a command is valid
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

lsb_dist=""

# Detect the OS distro, we support ubuntu, debian, mint, centos, fedora dist
detect_lsb() {
    # TODO: remove this when ARM support is fully merged
    case "$(uname -m)" in
        *64)
            ;;
         *)
            echo "Error: We currently only support 64-bit platforms."
            exit 1
            ;;
    esac

    if command_exists lsb_release; then
        lsb_dist="$(lsb_release -si)"
    fi
    if [ -z ${lsb_dist} ] && [ -r /etc/lsb-release ]; then
        lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
    fi
    if [ -z ${lsb_dist} ] && [ -r /etc/debian_version ]; then
        lsb_dist='debian'
    fi
    if [ -z ${lsb_dist} ] && [ -r /etc/fedora-release ]; then
        lsb_dist='fedora'
    fi
    if [ -z ${lsb_dist} ] && [ -r /etc/os-release ]; then
        lsb_dist="$(. /etc/os-release && echo "$ID")"
    fi

    lsb_dist="$(echo ${lsb_dist} | tr '[:upper:]' '[:lower:]')"

    case "${lsb_dist}" in
        amzn|centos|debian|ubuntu|coreos)
            ;;
        *)
            echo "Error: We currently only support ubuntu|debian|amzn|centos|coreos."
            exit 1
            ;;
    esac
}


# Start the bootstrap daemon
# TODO: do not start docker-bootstrap if it's already running
bootstrap_daemon() {
    # Detecting docker version so we could run proper docker_daemon command
    [[ $(eval "docker --version") =~ ([0-9][.][0-9][.][0-9]*) ]] && version="${BASH_REMATCH[1]}"
    local got=$(echo -e "${version}\n1.8.0" | sed '/^$/d' | sort -nr | head -1)
    if [[ "${got}" = "${version}" ]]; then
        docker_daemon="docker -d"
    else
        docker_daemon="docker daemon"
    fi
    # for docker 1.11.1 add --exec-root=/var/lib/docker-bootstrap :
    # https://github.com/kubernetes/kubernetes/issues/24654
    # https://github.com/docker/docker/issues/22684
    ${docker_daemon} \
        -H $FLANNEL_DOCKER_SOCK \
        -p /var/run/docker-bootstrap.pid \
        --iptables=false \
        --ip-masq=false \
        --bridge=none \
        --graph=/var/lib/docker-bootstrap \
        --exec-root=/var/lib/docker-bootstrap \
            2> /var/log/docker-bootstrap.log \
            1> /dev/null &

    sleep 5
}

# Start k8s components in containers
DOCKER_CONF=""

start_flannel(){
    # Start etcd
    docker -H $FLANNEL_DOCKER_SOCK run \
        --restart=on-failure \
        --net=host \
        -d \
        typhoon1986/etcd-${ARCH}:${ETCD_VERSION} \
        /usr/local/bin/etcd \
            --listen-client-urls=http://127.0.0.1:4001,http://${MASTER_IP}:4001 \
            --advertise-client-urls=http://${MASTER_IP}:4001 \
            --data-dir=/var/etcd/data

    sleep 5
    # Set flannel net config
    docker -H $FLANNEL_DOCKER_SOCK run \
        --net=host typhoon1986/etcd:${ETCD_VERSION} \
        etcdctl \
        set /coreos.com/network/config \
            '{ "Network": "10.1.0.0/16", "Backend": {"Type": "vxlan"}}'

    # iface may change to a private network interface, eth0 is for default
    flannelCID=$(docker -H $FLANNEL_DOCKER_SOCK run \
        --restart=on-failure \
        -d \
        --net=host \
        --privileged \
        -v /dev/net:/dev/net \
        typhoon1986/flannel:${FLANNEL_VERSION} \
        /opt/bin/flanneld \
            --ip-masq="${FLANNEL_IPMASQ}" \
            --iface="${FLANNEL_IFACE}")

    sleep 8
}

config_docker_network(){
    # Copy flannel env out and source it on the host
    flannelCID=$(docker -H ${FLANNEL_DOCKER_SOCK} ps | grep flannel | grep -v grep | awk '{print $1}')
    docker -H $FLANNEL_DOCKER_SOCK 
       # cp ${flannelCID}:/run/flannel/subnet.env .
    source ./subnet.env

    # Configure docker net settings, then restart it
    case "${lsb_dist}" in
        amzn)
            DOCKER_CONF="/etc/sysconfig/docker"
            echo "OPTIONS=\"\$OPTIONS --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
            ifconfig docker0 down
            yum -y -q install bridge-utils && brctl delbr docker0 && service docker restart
            ;;
        coreos)
            # disable selinux for docker issues
            DOCKER_CONF="/run/flannel_docker_opts.env"
            echo "DOCKER_OPTS=\"--selinux-enabled=false\"" | tee -a ${DOCKER_CONF}
            if [ "$BOOTSTRAP_FLANNEL" == "true" ]; then
              # delete lines if exists
              sed -i "/DOCKER_OPT_BIP.*/d" $DOCKER_CONF
              sed -i "/DOCKER_OPT_MTU.*/d" $DOCKER_CONF
              # use env file to setup docker daemon
              echo "DOCKER_OPT_BIP=\"--bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
              echo "DOCKER_OPT_MTU=\"--mtu=${FLANNEL_MTU}\"" | tee -a ${DOCKER_CONF}
            fi
            ifconfig docker0 down
            brctl delbr docker0 && systemctl restart docker
            ;;
        centos)
            # FIXME: use EnvironmentFile, why centos systemd not work?
            # use systemd drop in instead of /etc/sysconfig/docker
            DOCKER_CONF="/etc/systemd/system/docker.service.d/docker.conf"
            if [ ! -f $DOCKER_CONF ]; then
              mkdir -p /etc/systemd/system/docker.service.d
            fi
            systemctl stop docker
            echo "[Service]
ExecStart=
ExecStart=/usr/bin/docker daemon -H fd:// --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}" | tee -a $DOCKER_CONF
            #echo "OPTIONS=\"\$OPTIONS --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
            if ! command_exists ifconfig; then
                yum -y -q install net-tools
            fi
            ifconfig docker0 down
            yum -y -q install bridge-utils && brctl delbr docker0 && systemctl restart docker
            ;;
        ubuntu|debian)
            DOCKER_CONF="/etc/default/docker"
            echo "DOCKER_OPTS=\"\$DOCKER_OPTS --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
            ifconfig docker0 down
            apt-get install bridge-utils
            brctl delbr docker0
            service docker stop
            while [ `ps aux | grep /usr/bin/docker | grep -v grep | wc -l` -gt 0 ]; do
                echo "Waiting for docker to terminate"
                sleep 1
            done
            service docker start
            ;;
        *)
            echo "Unsupported operations system ${lsb_dist}"
            exit 1
            ;;
    esac

    # sleep a little bit
    sleep 5
}

start_kubelet(){
    # Change bind ip of apiserver
    mkdir -p /etc/kubernetes/manifests-multi
    sed "s/MASTER_IP/${MASTER_IP}/g" master.json > /etc/kubernetes/manifests-multi/master.json
    sed "s/MASTER_IP/${MASTER_IP}/g" kube-proxy.json > /etc/kubernetes/manifests-multi/kube-proxy.json
    # Start kubelet and then start master components as pods
    docker run \
        --net=host \
        --pid=host \
        --privileged \
        --restart=on-failure \
        -d \
        -v /sys:/sys:ro \
        -v /var/run:/var/run:rw \
        -v /:/rootfs:ro \
        -v /var/lib/docker/:/var/lib/docker:rw \
        -v /var/lib/kubelet/:/var/lib/kubelet:rw \
        -v /etc/kubernetes/manifests-multi:/etc/kubernetes/manifests-multi:rw \
        typhoon1986/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube kubelet \
            --pod_infra_container_image="typhoon1986/pause:2.0" \
            --address=0.0.0.0 \
            --allow-privileged=true \
            --enable-server \
            --api-servers=http://${MASTER_IP}:8080 \
            --config=/etc/kubernetes/manifests-multi \
            --cluster-dns=10.0.0.10 \
            --cluster-domain=cluster.local \
            --containerized \
            --v=2

}

echo "Detecting your OS distro ..."
detect_lsb

if [ "$BOOTSTRAP_FLANNEL" == "true" ]; then
  echo "Starting bootstrap docker ..."
  bootstrap_daemon

  echo "start flannel service within bootstrap docker ..."
  start_flannel
fi

echo "config docker network to work with flannel ..."

config_docker_network

echo "start kublet service ..."
start_kubelet

echo "Master done!"
