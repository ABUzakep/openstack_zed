#!/usr/bin/env bash

set -o errexit -o nounset

TOP_DIR=$(cd $(cat "../TOP_DIR" 2>/dev/null||echo $(dirname "$0"))/.. && pwd)

source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Memcached
#------------------------------------------------------------------------------

echo "Installing memcache packages."
sudo apt install -y memcached python3-memcache

MGMT_IP=$(get_node_ip_in_network "$(hostname)" "mgmt")
echo "Binding memcached server to $MGMT_IP."

conf=/etc/memcached.conf
sudo sed -i "s/^-l 127.0.0.1/-l $MGMT_IP/" $conf

echo "Restarting memcache service and verify."
sudo systemctl restart memcached
sudo systemctl enable memcached
sudo systemctl status memcached

