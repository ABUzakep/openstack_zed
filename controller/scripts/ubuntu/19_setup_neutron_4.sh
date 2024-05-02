#!/usr/bin/env bash

set -o errexit -o nounset

TOP_DIR=$(cd $(cat "../TOP_DIR" 2>/dev/null||echo $(dirname "$0"))/.. && pwd)

source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$CONFIG_DIR/openstack"
source "$LIB_DIR/functions.guest.sh"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up OpenStack Networking (neutron) for controller node.
#------------------------------------------------------------------------------

source "$CONFIG_DIR/admin-openstackrc.sh"

neutron_admin_user=neutron

# Wait for keystone to come up
wait_for_keystone

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Configure the metadata agent
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Configuring the metadata agent."
conf=/etc/neutron/metadata_agent.ini
iniset_sudo $conf DEFAULT nova_metadata_host controller
iniset_sudo $conf DEFAULT metadata_proxy_shared_secret "$METADATA_SECRET"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Configure the Compute service to use the Networking service
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Configuring Compute to use Networking."
conf=/etc/nova/nova.conf
iniset_sudo $conf neutron auth_url http://controller:5000
iniset_sudo $conf neutron auth_type password
iniset_sudo $conf neutron project_domain_name default
iniset_sudo $conf neutron user_domain_name default
iniset_sudo $conf neutron region_name "$REGION"
iniset_sudo $conf neutron project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf neutron username "$neutron_admin_user"
iniset_sudo $conf neutron password "$NEUTRON_PASS"
iniset_sudo $conf neutron service_metadata_proxy true
iniset_sudo $conf neutron metadata_proxy_shared_secret "$METADATA_SECRET"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Finalize installation
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Populating the database."
sudo neutron-db-manage \
    --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
    upgrade head

echo "Restarting nova services."
sudo systemctl restart nova-api

echo "Restarting neutron-server."
sudo systemctl restart neutron-server

echo "Restarting neutron-linuxbridge-agent."
sudo systemctl restart neutron-linuxbridge-agent

echo "Restarting neutron-dhcp-agent."
sudo systemctl restart neutron-dhcp-agent

echo "Restarting neutron-metadata-agent."
sudo systemctl restart neutron-metadata-agent

if type neutron-l3-agent; then
    # Installed only for networking option 2 of the install-guide.
    echo "Restarting neutron-l3-agent."
    sudo systemctl restart neutron-l3-agent
fi

#------------------------------------------------------------------------------
# Set up OpenStack Networking (neutron) for controller node.
#------------------------------------------------------------------------------

echo -n "Verifying operation."
until openstack network agent list >/dev/null 2>&1; do
    sleep 1
    echo -n .
done
echo

openstack network agent list
