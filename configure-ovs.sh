#!/bin/bash
set -eux
# Workaround to ensure OVS is installed due to bug in systemd Requires:
# https://bugzilla.redhat.com/show_bug.cgi?id=1888017
copy_nm_conn_files() {
  src_path="/etc/NetworkManager/system-connections-merged"
  dst_path="/etc/NetworkManager/system-connections"
  if [ -d $src_path ]; then
    echo "$src_path exists"
    fileList=$(echo {br-ex,ovs-if-br-ex,ovs-port-br-ex,ovs-if-phys0,ovs-port-phys0}.nmconnection)
    for file in ${fileList[*]}; do
      if [ ! -f $dst_path/$file ]; then
        cp $src_path/$file $dst_path/$file
      else
        echo "Skipping $file since it exists in $dst_path"
      fi
    done
  fi
}

if ! rpm -qa | grep -q openvswitch; then
  echo "Warning: Openvswitch package is not installed!"
  exit 1
fi

if [ "$1" == "OVNKubernetes" ]; then
  # Configures NICs onto OVS bridge "br-ex"
  # Configuration is either auto-detected or provided through a config file written already in Network Manager
  # key files under /etc/NetworkManager/system-connections/
  # Managing key files is outside of the scope of this script

  # if the interface is of type vmxnet3 add multicast capability for that driver
  # REMOVEME: Once BZ:1854355 is fixed, this needs to get removed.
  function configure_driver_options {
    intf=$1
    driver=$(cat "/sys/class/net/${intf}/device/uevent" | grep DRIVER | awk -F "=" '{print $2}')
    echo "Driver name is" $driver
    if [ "$driver" = "vmxnet3" ]; then
      ifconfig "$intf" allmulti
    fi
  }
  if [ -d "/etc/NetworkManager/system-connections-merged" ]; then
    NM_CONN_PATH="/etc/NetworkManager/system-connections-merged"
  else
    NM_CONN_PATH="/etc/NetworkManager/system-connections"
  fi
  iface=""
  counter=0
  # find default interface
  while [ $counter -lt 12 ]; do
    # check ipv4
    iface=$(ip route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
    if [[ -n "$iface" ]]; then
      echo "IPv4 Default gateway interface found: ${iface}"
      break
    fi
    # check ipv6
    iface=$(ip -6 route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
    if [[ -n "$iface" ]]; then
      echo "IPv6 Default gateway interface found: ${iface}"
      break
    fi
    counter=$((counter+1))
    echo "No default route found on attempt: ${counter}"
    sleep 5
  done

  if [ "$iface" = "br-ex" ]; then
    # handle vlans and bonds etc if they have already been
    # configured via nm key files and br-ex is already up
    ifaces=$(ovs-vsctl list-ifaces ${iface})
    for intf in $ifaces; do configure_driver_options $intf; done
    echo "Networking already configured and up for br-ex!"
    # remove bridges created by openshift-sdn
    ovs-vsctl --timeout=30 --if-exists del-br br0
    exit 0
  fi

  if [ -z "$iface" ]; then
    echo "ERROR: Unable to find default gateway interface"
    exit 1
  fi

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

  extra_brex_args=""
  # check for dhcp client ids
  dhcp_client_id=$(nmcli --get-values ipv4.dhcp-client-id conn show ${old_conn})
  if [ -n "$dhcp_client_id" ]; then
    extra_brex_args+="ipv4.dhcp-client-id ${dhcp_client_id} "
  fi

  dhcp6_client_id=$(nmcli --get-values ipv6.dhcp-duid conn show ${old_conn})
  if [ -n "$dhcp6_client_id" ]; then
    extra_brex_args+="ipv6.dhcp-duid ${dhcp6_client_id} "
  fi

  # create bridge; use NM's ethernet device default route metric (100)
  if ! nmcli connection show br-ex &> /dev/null; then
    nmcli c add type ovs-bridge \
        con-name br-ex \
        conn.interface br-ex \
        802-3-ethernet.mtu ${iface_mtu} \
        802-3-ethernet.cloned-mac-address ${iface_mac} \
        ipv4.route-metric 100 \
        ipv6.route-metric 100 \
        ${extra_brex_args}
  fi

  # find default port to add to bridge
  if ! nmcli connection show ovs-port-phys0 &> /dev/null; then
    nmcli c add type ovs-port conn.interface ${iface} master br-ex con-name ovs-port-phys0
  fi

  if ! nmcli connection show ovs-port-br-ex &> /dev/null; then
    nmcli c add type ovs-port conn.interface br-ex master br-ex con-name ovs-port-br-ex
  fi

  extra_phys_args=""
  # check if this interface is a vlan, bond, or ethernet type
  if [ $(nmcli --get-values connection.type conn show ${old_conn}) == "vlan" ]; then
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
  elif [ $(nmcli --get-values connection.type conn show ${old_conn}) == "bond" ]; then
    iface_type=bond
    # check bond options
    bond_opts=$(nmcli --get-values bond.options conn show ${old_conn})
    if [ -n "$bond_opts" ]; then
      extra_phys_args+="bond.options ${bond_opts} "
    fi
  else
    iface_type=802-3-ethernet
  fi

  # bring down any old iface
  nmcli device disconnect $iface

  if ! nmcli connection show ovs-if-phys0 &> /dev/null; then
    nmcli c add type ${iface_type} conn.interface ${iface} master ovs-port-phys0 con-name ovs-if-phys0 \
      connection.autoconnect-priority 100 802-3-ethernet.mtu ${iface_mtu} ${extra_phys_args}
  fi

  nmcli conn up ovs-if-phys0

  if ! nmcli connection show ovs-if-br-ex &> /dev/null; then
    if nmcli --fields ipv4.method,ipv6.method conn show $old_conn | grep manual; then
      echo "Static IP addressing detected on default gateway connection: ${old_conn}"
      # find and copy the old connection to get the address settings
      if egrep -l --include=*.nmconnection uuid=$old_conn ${NM_CONN_PATH}/*; then
        old_conn_file=$(egrep -l --include=*.nmconnection uuid=$old_conn ${NM_CONN_PATH}/*)
        cloned=false
      else
        echo "WARN: unable to find NM configuration file for conn: ${old_conn}. Attempting to clone conn"
        old_conn_file=${NM_CONN_PATH}/${old_conn}-clone.nmconnection
        nmcli conn clone ${old_conn} ${old_conn}-clone
        cloned=true
        if [ ! -f "$old_conn_file" ]; then
          echo "ERROR: unable to locate cloned conn file: ${old_conn_file}"
          exit 1
        fi
        echo "Successfully cloned conn to ${old_conn_file}"
      fi
      echo "old connection file found at: ${old_conn_file}"
      new_conn_file=${NM_CONN_PATH}/ovs-if-br-ex.nmconnection
      if [ -f "$new_conn_file" ]; then
        echo "WARN: existing br-ex interface file found: $new_conn_file, which is not loaded in NetworkManager...overwriting"
      fi
      cp -f ${old_conn_file} ${new_conn_file}
      restorecon ${new_conn_file}
      if $cloned; then
        nmcli conn delete ${old_conn}-clone
        rm -f ${old_conn_file}
      fi
      ovs_port_conn=$(nmcli --fields connection.uuid conn show ovs-port-br-ex | awk '{print $2}')
      br_iface_uuid=$(cat /proc/sys/kernel/random/uuid)
      # modify file to work with OVS and have unique settings
      sed -i '/^\[connection\]$/,/^\[/ s/^uuid=.*$/uuid='"$br_iface_uuid"'/' ${new_conn_file}
      sed -i '/^multi-connect=.*$/d' ${new_conn_file}
      sed -i '/^\[connection\]$/,/^\[/ s/^type=.*$/type=ovs-interface/' ${new_conn_file}
      sed -i '/^\[connection\]$/,/^\[/ s/^id=.*$/id=ovs-if-br-ex/' ${new_conn_file}
      sed -i '/^\[connection\]$/a slave-type=ovs-port' ${new_conn_file}
      sed -i '/^\[connection\]$/a master='"$ovs_port_conn" ${new_conn_file}
      if grep 'interface-name=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[connection\]$/,/^\[/ s/^interface-name=.*$/interface-name=br-ex/' ${new_conn_file}
      else
        sed -i '/^\[connection\]$/a interface-name=br-ex' ${new_conn_file}
      fi
      if ! grep 'cloned-mac-address=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[ethernet\]$/a cloned-mac-address='"$iface_mac" ${new_conn_file}
      else
        sed -i '/^\[ethernet\]$/,/^\[/ s/^cloned-mac-address=.*$/cloned-mac-address='"$iface_mac"'/' ${new_conn_file}
      fi
      if grep 'mtu=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[ethernet\]$/,/^\[/ s/^mtu=.*$/mtu='"$iface_mtu"'/' ${new_conn_file}
      else
        sed -i '/^\[ethernet\]$/a mtu='"$iface_mtu" ${new_conn_file}
      fi
      cat <<EOF >> ${new_conn_file}
[ovs-interface]
type=internal
EOF
      nmcli c load ${new_conn_file}
      echo "Loaded new ovs-if-br-ex connection file: ${new_conn_file}"
    else
      nmcli c add type ovs-interface slave-type ovs-port conn.interface br-ex master ovs-port-br-ex con-name \
        ovs-if-br-ex 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac} \
        ipv4.route-metric 100 ipv6.route-metric 100
    fi
  fi

  # wait for DHCP to finish, verify connection is up
  counter=0
  while [ $counter -lt 5 ]; do
    sleep 5
    # check if connection is active
    if nmcli --fields GENERAL.STATE conn show ovs-if-br-ex | grep -i "activated"; then
      echo "OVS successfully configured"
      copy_nm_conn_files
      ip a show br-ex
      ip route show
      configure_driver_options ${iface}
      exit 0
    fi
    counter=$((counter+1))
  done

  echo "WARN: OVS did not succesfully activate NM connection. Attempting to bring up connections"
  counter=0
  while [ $counter -lt 5 ]; do
    if nmcli conn up ovs-if-br-ex; then
      echo "OVS successfully configured"
      copy_nm_conn_files
      ip a show br-ex
      ip route show
      configure_driver_options ${iface}
      exit 0
    fi
    sleep 5
    counter=$((counter+1))
  done

  echo "ERROR: Failed to activate ovs-if-br-ex NM connection"
  # if we made it here networking isnt coming up, revert for debugging
  set +e
  nmcli conn down ovs-if-br-ex
  nmcli conn down ovs-if-phys0
  nmcli conn up $old_conn
  exit 1
elif [ "$1" == "OpenShiftSDN" ]; then
  # Revert changes made by /usr/local/bin/configure-ovs.sh.
  # Remove OVS bridge "br-ex". Use the default NIC for cluster network.
  iface=""
  if nmcli connection show ovs-port-phys0 &> /dev/null; then
    iface=$(nmcli --get-values connection.interface-name connection show ovs-port-phys0)
    nmcli c del ovs-port-phys0
  fi

  if nmcli connection show ovs-if-phys0 &> /dev/null; then
    nmcli c del ovs-if-phys0
  fi

  if nmcli connection show ovs-port-br-ex &> /dev/null; then
    nmcli c del ovs-port-br-ex
  fi

  if nmcli connection show ovs-if-br-ex &> /dev/null; then
    nmcli c del ovs-if-br-ex
  fi

  if nmcli connection show br-ex &> /dev/null; then
    nmcli c del br-ex
  fi

  rm -f /etc/NetworkManager/system-connections/{br-ex,ovs-if-br-ex,ovs-port-br-ex,ovs-if-phys0,ovs-port-phys0}.nmconnection
  # remove bridges created by ovn-kubernetes, try to delete br-ex again in case NM fail to talk to ovsdb
  ovs-vsctl --timeout=30 --if-exists del-br br-int -- --if-exists del-br br-local -- --if-exists del-br br-ex

  if [[ -n "$iface" ]]; then
    nmcli device connect $iface
  fi
fi
