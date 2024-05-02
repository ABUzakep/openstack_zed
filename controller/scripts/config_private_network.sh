#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd $(cat "../TOP_DIR" 2>/dev/null||echo $(dirname "$0"))/.. && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Create private network
#------------------------------------------------------------------------------

echo -n "Waiting for first DHCP namespace."
until [ "$(ip netns | grep -c -o "^qdhcp-[a-z0-9-]*")" -gt 0 ]; do
    sleep 1
    echo -n .
done
echo

echo -n "Waiting for first bridge to show up."
# Bridge names are something like brq219ddb93-c9
until [ "$(sudo brctl show | grep -c -o "^brq[a-z0-9-]*")" -gt 0 ]; do
    sleep 1
    echo -n .
done
echo

# Wait for neutron to start
wait_for_neutron

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Create the self-service network
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

(
echo "Sourcing the demo credentials."
source "$CONFIG_DIR/demo-openstackrc.sh"

echo "Creating the private network."
openstack network create selfservice

echo "Creating a subnet on the private network."
openstack subnet create --network selfservice \
    --dns-nameserver "$DNS_RESOLVER" --gateway "$SELFSERVICE_NETWORK_GATEWAY" \
    --subnet-range "$SELFSERVICE_NETWORK_CIDR" selfservice
)

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Not in install-guide:
echo -n "Waiting for second DHCP namespace."
until [ "$(ip netns | grep -c -o "^qdhcp-[a-z0-9-]*")" -gt 1 ]; do
    sleep 1
    echo -n .
done
echo

echo -n "Waiting for second bridge."
until [ "$(sudo brctl show | grep -c -o "^brq[a-z0-9-]*")" -gt 1 ]; do
    sleep 1
    echo -n .
done
echo

echo "Bridges are:"
sudo brctl show

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Create a router
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

(
echo "Sourcing the demo credentials."
source "$CONFIG_DIR/demo-openstackrc.sh"

echo "Creating a router."
openstack router create router
)

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Not in install-guide:

function wait_for_agent {
    local agent=$1

    echo -n "Waiting for neutron agent $agent."
    (
    source "$CONFIG_DIR/admin-openstackrc.sh"
    while openstack network agent list | grep "$agent" | grep -q "XXX"; do
        sleep 1
        echo -n .
    done
    echo
    )
}

wait_for_agent neutron-l3-agent

echo "linuxbridge-agent and dhcp-agent must be up before we can add interfaces."
wait_for_agent neutron-linuxbridge-agent
wait_for_agent neutron-dhcp-agent

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
(
source "$CONFIG_DIR/demo-openstackrc.sh"

echo "Adding the private network subnet as an interface on the router."
openstack router add subnet router selfservice
)
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# The following tests for router namespace, qr-* interface and bridges are just
# for show. They are not needed to prevent races.

echo -n "Getting router namespace."
until ip netns | grep qrouter; do
    echo -n "."
    sleep 1
done

export nsrouter=$(ip netns | grep qrouter | awk '{print $1}')

echo "$nsrouter Router Found "

echo -n "Waiting for interface qr-* in router namespace."
until sudo ip netns exec $nsrouter ip a|grep -Po "(?<=: )qr-.*(?=:)" ; do
    echo -n "."
    sleep 1
done

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
(
source "$CONFIG_DIR/demo-openstackrc.sh"

echo "Setting a gateway on the public network on the router."
openstack router set router --external-gateway provider
)

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# The following test for qg-* is just for show.
echo -n "Waiting for interface qg-* in router namespace."
until sudo ip netns exec "$nsrouter" ip addr|grep -Po "(?<=: )qg-.*(?=:)"; do
   echo -n "."
   sleep 1
done

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Verify operation
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "Listing network namespaces."
ip netns

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openstackrc.sh"

echo "Getting the router's IP address in the public network."
echo "openstack port list --router router"
openstack port list --router router

# Get router IP address in given network
function get_router_ip_address {
    local net_name=$1
    local public_network=$(netname_to_network "$net_name")
    local network_part=$(remove_last_octet "$public_network")
    local line

    while : ; do
        line=$(openstack port list --router router -c"Fixed IP Addresses" | grep "$network_part")
        if [ -z "$line" ]; then
            # Wait for the network_part to appear in the list
            sleep 1
            echo -n >&2 .
            continue
        fi
        router_ip=$(echo "$line"|grep -Po "$network_part\.\d+")
        echo "$router_ip"
        return 0
    done
}

PUBLIC_ROUTER_IP=$(get_router_ip_address "provider")

echo -n "Waiting for ping reply from public router IP ($PUBLIC_ROUTER_IP)."
cnt=0
until ping -c1 "$PUBLIC_ROUTER_IP" > /dev/null; do
    cnt=$((cnt + 1))
    if [ $cnt -eq 20 ]; then
        echo "ERROR No reply from public router IP in 20 seconds, aborting."
        exit 1
    fi
    sleep 1
    echo -n .
done
echo
