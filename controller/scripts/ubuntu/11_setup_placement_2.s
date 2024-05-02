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
# Install Placement services
#------------------------------------------------------------------------------

echo "Setting up placement database."
setup_database placement "$PLACEMENT_DB_USER" "$PLACEMENT_DBPASS"

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openrc.sh"

placement_admin_user=placement

# Wait for keystone to come up
wait_for_keystone

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
echo "Creating placement user and giving it the admin role."
openstack user create \
    --domain default  \
    --password "$PLACEMENT_PASS" \
    "$placement_admin_user"

openstack role add \
    --project "$SERVICE_PROJECT_NAME" \
    --user "$placement_admin_user" \
    "$ADMIN_ROLE_NAME"

echo "Creating the Placement API entry in the service catalog."
openstack service create \
    --name placement \
    --description "Placement API" \
    placement

echo "Creating placement endpoints."
openstack endpoint create \
    --region "$REGION" \
    placement public http://controller:8778

openstack endpoint create \
    --region "$REGION" \
    placement internal http://controller:8778

openstack endpoint create \
    --region "$REGION" \
    placement admin http://controller:8778

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Configure components
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Reduce memory usage (not in install-guide)
conf=/etc/apache2/sites-enabled/placement-api.conf
sudo sed -i --follow-symlinks '/WSGIDaemonProcess/ s/processes=[0-9]*/processes=1/' $conf
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

conf=/etc/placement/placement.conf

# Configure [placement_database] section.
database_url="mysql+pymysql://$PLACEMENT_DB_USER:$PLACEMENT_DBPASS@controller/placement"
echo "Setting placement database connection: $database_url."
iniset_sudo $conf placement_database connection "$database_url"

iniset_sudo $conf api auth_strategy keystone

echo "Configuring Placement services."
iniset_sudo $conf keystone_authtoken auth_url http://controller:5000/v3
iniset_sudo $conf keystone_authtoken memcached_servers controller:11211
iniset_sudo $conf keystone_authtoken auth_type password
iniset_sudo $conf keystone_authtoken project_domain_name Default
iniset_sudo $conf keystone_authtoken user_domain_name Default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$placement_admin_user"
iniset_sudo $conf keystone_authtoken password "$PLACEMENT_PASS"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
echo "Populating the placement database."
sudo placement-manage db sync

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Finalize installation
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Restarting apache2."
sudo systemctl restart apache2

#------------------------------------------------------------------------------
# Verify the Placement controller installation
#------------------------------------------------------------------------------

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openstackrc.sh"

# Wait for keystone to come up
wait_for_keystone

# placement-status upgrade check

echo "Performing status check."
sudo placement-status upgrade check

echo "Listing available resource classes and traits."
openstack --os-placement-api-version 1.2 resource class list --sort-column name
openstack --os-placement-api-version 1.6 trait list --sort-column name
