#!/bin/bash

# Script to migrate an OCP OVN-K node to a new interface
# script takes the old and new interface/NIC to migrate to as arguments
# ./migrateOVN.sh ens3 ens8

detected_conn=""

copy_nm_conn_files() {
  src_path="/etc/NetworkManager/system-connections-merged"
  dst_path="/etc/NetworkManager/system-connections"
  if [ -d $src_path ]; then
    echo "$src_path exists"
    fileList=$(echo {br-ex,ovs-if-br-ex,ovs-if-phys0,ovs-port-phys0}.nmconnection)
    for file in ${fileList[*]}; do
      if [ -f $src_path/$file ]; then
        cp -f $src_path/$file $dst_path/$file
      else
        echo "Skipping $file since it does not exist in $src_path"
      fi
    done
  fi
}

find_nm_conn_for_device() {
  local new_device
  conns=$(nmcli --fields UUID conn show | sed 1d)
  while IFS= read -r conn; do
    new_device=$(nmcli --get-values connection.interface-name conn show ${conn})
    if [ "$new_device" = "$1" ]; then
      echo "Detected connection ${conn} for device ${1}"
      detected_conn=$(echo ${conn} | tr -d '[:space:]')
      return
    fi
  done <<< "$conns"
  return 1
}

if [ -z "$1" ]; then
    echo "This script requires an argument for the interface name to migrate from"
    exit 1
fi

if [ -z "$2" ]; then
    echo "This script requires an argument for the interface name to migrate to"
    exit 1
fi

set -eux

old_iface=$1
iface=$2

for port in ${old_iface} ${iface}; do
  if ! nmcli device show ${port}; then
    echo "NIC: ${port} not detected on this node"
    # device is not present need to search and bring them up
    if find_nm_conn_for_device ${port}; then
      echo "Bringing up connection ${detected_conn}"
      retries=5
      i=1
      while [ $i -le $retries ]; do
        if nmcli conn up "${detected_conn}"; then
          echo "Connection ${detected_conn} up successfully"
          break
        fi
        echo "Failed to bring up connection ${detected_conn}. Attempt: $i of ${retries}"
        sleep 5
        i=$((i+1))
      done
      if [ $i -gt $retries ]; then
        echo "Failed to bring up connection ${detected_conn} after ${retries} retries...there must be an active \
          connection for migration for device ${port}"
        exit 1
      fi
    else
      echo "unable to find corresponding connection for device ${port}"
      exit 1
    fi
  else
    if ! nmcli device connect ${port}; then
      echo "Unable to ensure device ${port} is up Network Manager"
      exit 1
    fi
  fi
done

new_conn=$(nmcli --get-values GENERAL.CONNECTION device show ${iface})

if [ -z "$new_conn" ]; then
  echo "No active NM connection found for device..."
  exit 1
elif [[ "$new_conn" == "ovs-if-phys0" || "$new_conn" == "ovs-port-phys0" ]]; then
  echo "Interface: ${iface} is already part of ovs-if-phys0 connection. Nothing to do..."
  exit 0
fi

if ! nmcli --fields GENERAL.STATE conn show br-ex; then
  echo "No current Network Manager connection for br-ex found. Please run ovs-configuration.sh first!"
  exit 1
fi

# Need to get IP info from the new connection so we can rebuild the OVS connections

# find the MAC from OVS config or the default interface to use for OVS internal port
 # this prevents us from getting a different DHCP lease and dropping connection
if ! iface_mac=$(<"/sys/class/net/${iface}/address"); then
  echo "Unable to determine default interface MAC"
  exit 1
fi

echo "MAC address found for iface: ${iface}: ${iface_mac}"

# find MTU from original iface
iface_mtu=$(ip link show "$iface" | awk '{print $5; exit}')
if [[ -z "$iface_mtu" ]]; then
  echo "Unable to determine default interface MTU, defaulting to 1500"
  iface_mtu=1500
else
  echo "MTU found for iface: ${iface}: ${iface_mtu}"
fi

# store old conn for later
old_conn=$(nmcli --fields UUID,DEVICE conn show --active | awk "/\s${iface}\s*\$/ {print \$1}")

# new args to update in br-ex
extra_brex_args="802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac}"

# check for dhcp client ids
dhcp_client_id=$(nmcli --get-values ipv4.dhcp-client-id conn show ${old_conn})
if [ -n "$dhcp_client_id" ]; then
  extra_brex_args+=" ipv4.dhcp-client-id ${dhcp_client_id} "
else
  extra_brex_args+=" -ipv4.dhcp-client-id"
fi

dhcp6_client_id=$(nmcli --get-values ipv6.dhcp-duid conn show ${old_conn})
if [ -n "$dhcp6_client_id" ]; then
  extra_brex_args+=" ipv6.dhcp-duid ${dhcp6_client_id} "
else
  extra_brex_args+=" -ipv6.dhcp-duid"
fi

# For migration the current interface in OVS is considered the requested default gw interface
# Therefore we use a much higher route metric on br-ex for the new interface so that default gw traffic
# will continue to flow via old iface
extra_brex_args+=" ipv4.route-metric 500 ipv6.route-metric 500"

# NM CONNECTION UPDATE: br-ex
if ! nmcli conn mod br-ex $extra_brex_args; then
  echo "Failed to update br-ex NM connection with args: ${extra_brex_args}"
  exit 1
fi

extra_phys_args="802-3-ethernet.mtu ${iface_mtu} conn.interface ${iface} "
# check if this interface is a vlan, bond, or ethernet type
if [ "$(nmcli --get-values connection.type conn show ${old_conn})" == "vlan" ]; then
  iface_type=vlan
  vlan_id=$(nmcli --get-values vlan.id conn show ${old_conn})
  if [ -z "$vlan_id" ]; then
    echo "ERROR: unable to determine vlan_id for vlan connection: ${old_conn}"
    exit 1
  fi
  vlan_parent=$(nmcli --get-values vlan.parent conn show ${old_conn})
  if [ -z "$vlan_parent" ]; then
    echo "ERROR: unable to determine vlan_parent for vlan connection: ${old_conn}"
    exit 1
  fi
  extra_phys_args="dev ${vlan_parent} id ${vlan_id}"
elif [ "$(nmcli --get-values connection.type conn show ${old_conn})" == "bond" ]; then
  iface_type=bond
  # check bond options
  bond_opts=$(nmcli --get-values bond.options conn show ${old_conn})
  if [ -n "$bond_opts" ]; then
    extra_phys_args+="bond.options ${bond_opts} "
  fi
else
  iface_type=802-3-ethernet
fi

# NM CONNECTION UPDATE: ovs-port-phys0
nmcli conn mod ovs-port-phys0 conn.interface ${iface}

# NM CONNECTION UPDATE: ovs-if-phys0
# we are unable to modify connection type, so if the user is migrating from a ethernet type to
# vlan or bond we cannot update the connection and must create a new one
current_iface_type=$(nmcli --get-values connection.type conn show ovs-if-phys0)
if [ "$current_iface_type" = "$iface_type" ]; then
  echo "Migration to and from interfaces are of the same type: ${iface_type}. Able to just update ovs-if-phys0"
  if ! nmcli conn mod ovs-if-phys0 $extra_phys_args; then
    echo "Failed to update ovs-if-phys0 connection with args: ${extra_phys_args}"
    exit 1
  fi
else
  echo "Migration from ${current_iface_type} to ${iface_type} detected. Will recreate ovs-if-phys0"
  nmcli conn delete ovs-if-phys0
  nmcli c add type ${iface_type} conn.interface ${iface} master ovs-port-phys0 con-name ovs-if-phys0 \
    connection.autoconnect-priority 100 802-3-ethernet.mtu ${iface_mtu} ${extra_phys_args}
fi

# NM CONNECTION UPDATE: ovs-if-br-ex
# For now we assume there is no static IP assignment. May support this later.
# We want no default route on br-ex, the default route will be provided by primary interface on the host
nmcli conn mod ovs-if-br-ex 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac} \
  ipv4.never-default yes ipv6.never-default yes

# bring down br-ex, bring back up br-ex, bring up old iface
nmcli conn down br-ex
nmcli conn up ovs-if-phys0
nmcli conn up ovs-if-br-ex
systemctl restart NetworkManager

# If we are on 4.7 or later there is the NM overlay so nmcli mods will only exist in merged files, so
# need to copy the overlay files back to the system conns
copy_nm_conn_files

echo "OVS Migration has completed updating Network Manager connections!"
