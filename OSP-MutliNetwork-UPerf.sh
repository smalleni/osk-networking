#!/bin/bash

#-------------------------------------------------------------------------------
# OSP-Network-Perf.sh
#
#
# -- To do --
# ----  
# ---- Currently now VLAN testing... This assumes there is a br-tun bridge
#
# -- Updates --
# 01/22/14 - moved to uperf, removed netperf
# 01/11/14 - uperf-bpench inital drop
# 07/16/14 - Super-netperf integration... Layed things down for FloatingIP
# 04/21/14 - Neutron changed how the flows are built. Previously there was a
#            signle flow for the dhcp-agent, now there is a per-guest flow
#            which is a bit more secure.
# 04/17/14 - Sync the throughput runs... Sync with Lock file 
# 03/18/14 - Fixes
# 02/20/14 - Working on Scale 
# 11/13/13 - Create a new security group, then remove it for the cleanup
# 11/12/13 - Added code to allow multiple launches of this script
# 11/11/13 - First drop
# @author Joe Talerico (jtaleric@redhat.com)
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Determine the Run - for multi-run 
#-------------------------------------------------------------------------------
RUN=0
if [ -z $1 ] ; then 
 RUN=1
else 
 echo Run : $1
 RUN=$1
fi

#----------------------- Test name ---------------------------------------------
if [ -z $2 ] ; then
 TESTNAME="no-name"
else
 echo Test name: $2
 TESTNAME=$2
fi

if [ -z $3 ] ; then
 FLAVOR="m1.small" 
else
 echo Flavor: $3
 FLAVOR=$3
fi

PLUG=true
HOST="neutron-n-0"
UPERF=true
SAMPLES=5
TESTS="stream"
PROTO="tcp"
ROUTER_ID="94361b6f-94ce-456f-97dd-aa1f012608eb"
SECGROUP=true
HIGH_INTERVAL=false
KEYSTONE_ADMIN="/root/keystonerc_admin"
NETPERF_IMG_NAME="pbench"
NETPERF_IMG=""
GUEST_SIZE=$FLAVOR
#----------------------- Currently not using Floating IPs ----------------------
VETH1="veth$RUN"
VETH2="veth"`expr $RUN + 1000`
#----------------------- Set the eth within the guest --------------------------
GUEST_VETH="eth0"

#----------------------- Store the results -------------------------------------
if [ -z $2 ] ; then 
 FOLDER=OSP-NetworkScale-Output_$(date +%Y_%m_%d_%H_%M_%S)
else
 FOLDER=$2
fi

#-------------------------------------------------------------------------------
# Folder where to store the the results of netperf and the output of 
# the OSP Script.
#-------------------------------------------------------------------------------
mkdir -p $FOLDER

#-------------------------------------------------------------------------------
# Set this to true if tunnels are used, set to false if VLANs are used.
#
# !! If VLANs are used, the user must setup the flows and veth before running !!
#-------------------------------------------------------------------------------
TUNNEL=false

#----------------------- Array to hold guest ID --------------------------------
declare -A GUESTS

#-------------------------------------------------------------------------------
# Clean will remove Network and Guest information
#-------------------------------------------------------------------------------
CLEAN=true

#----------------------- Show Debug output -------------------------------------
DEBUG=false

#-------------------------------------------------------------------------------
# CLEAN_IMAGE will remove the netperf-networktest image from glance
#-------------------------------------------------------------------------------
CLEAN_IMAGE=false

#----------------------- Hosts to Launch Guests  -------------------------------
ZONE[0]="nova:macb8ca3a60ff54.perf.lab.eng.bos.redhat.com"
ZONE[1]="nova:macb8ca3a6106b4.perf.lab.eng.bos.redhat.com"

#----------------------- Network -----------------------------------------------
TUNNEL_NIC="enp4s0f0"
TUNNEL_SPEED=`ethtool ${TUNNEL_NIC} | grep Speed | sed 's/\sSpeed: \(.*\)Mb\/s/\1/'`
TUNNEL_TYPE=`ovs-vsctl show | grep -E 'Port.*gre|vxlan|stt*'`
NETWORK="private-${RUN}"
SUBNET="10.0.${RUN}.0/24"
INTERFACE="10.0.${RUN}.150/14"
SUB_SEARCH="10.0.${RUN}."
MTU=8950
SSHKEY="/root/.ssh/id_rsa.pub"
SINGLE_TUNNEL_TEST=true

#----------------------- No Code.... yet. --------------------------------------
MULTI_TUNNEL_TEST=false
#----------------------- Need to determine how to tell ( ethtool? STT ) --------
HARDWARE_OFFLOAD=false 
#----------------------- Is Jumbo Frames enabled throughout? -------------------
JUMBO=false
#----------------------- Ignore DHCP MTU ---------------------------------------
DHCP=true

#-------------------------------------------------------------------------------
# Params to set the guest MTU lower to account for tunnel overhead
# or if JUMBO is enabled to increase MTU
#-------------------------------------------------------------------------------
if $DHCP ; then
if $TUNNEL ; then
 MTU=1500
 if $JUMBO ; then
  MTU=8950
 fi
fi
fi

#-------------------------------------------------------------------------------
# Must have admin rights to run this...
#-------------------------------------------------------------------------------
if [ -f $KEYSTONE_ADMIN ]; then
 source $KEYSTONE_ADMIN 
else 
 echo "ERROR :: Unable to source keystone_admin file"
 exit 1
fi

if ! [ -f $NETPERF_IMG ]; then 
 echo "WARNING :: Unable to find the Netperf image"
 echo "You must import the image before running this script"
fi

#-------------------------------------------------------------------------------
# cleanup()
#  
#
#
#
#-------------------------------------------------------------------------------
cleanup() {
 echo "#-------------------------------------------------------------------------------"
 echo "Cleaning up...."
 echo "#-------------------------------------------------------------------------------"
 if [ -n "$search_string" ] ; then
  echo "Cleaning netperf Guests"
  for key in ${search_string/|/ } 
  do 
   key=${key%"|"}
   echo "Removing $key...."
   nova delete $key
  done
 fi

#-------------------------------------------------------------------------------
# Is Nova done deleting?
#-------------------------------------------------------------------------------
  while true; 
  do
   glist=`nova list | grep -E ${search_string%?} | awk '{print $2}'` 
   if [ -z "$glist" ] ; then
    break
   fi
   sleep 5
  done

#-------------------------------------------------------------------------------
# Remove test Networks
#-------------------------------------------------------------------------------
 nlist=$(neutron subnet-list | grep "${SUBNET}" | awk '{print $2}') 
 if ! [ -z "$nlist" ] ; then 
  echo "Cleaning test networks..."
  neutron subnet-delete $(neutron subnet-list | grep "${SUBNET}" | awk '{print $2}')
  neutron net-delete $NETWORK
 fi

 if $CLEAN_IMAGE ; then
  ilist=$(glance image-list | grep netperf | awk '{print $2}')
  if ! [ -z "$ilist" ] ; then
   echo "Cleaning Glance..."
   yes | glance image-delete $ilist
  fi
 fi 

 ip link delete $VETH1
 ovs-vsctl del-port $VETH2

} #END cleanup

if [ -z "$(neutron net-list | grep "${NETWORK}")" ]; then 
#----------------------- Create Subnet  ----------------------------------------
 echo "#-------------------------------------------------------------------------------"
 echo "Creating Subnets "
 echo "#-------------------------------------------------------------------------------"
 neutron net-create $NETWORK 
 neutron subnet-create $NETWORK $SUBNET 
 neutron net-show $NETWORK 
fi 

NETWORKID=`nova network-list | grep -e "${NETWORK}\s" | awk '{print $2}'` 
if $DEBUG  ; then
 echo "#----------------------- Debug -------------------------------------------------"
 echo "Network ID :: $NETWORKID"
 echo "#-------------------------------------------------------------------------------"
fi

neutron router-interface-add $ROUTER_ID `neutron net-list | grep ${NETWORKID} | awk '{print $6}'` 

if $PLUG ; then
 echo "#------------------------------------------------------------------------------- "
 echo "Plugging Neutron"
 echo "#-------------------------------------------------------------------------------"
 PORT_INFO=$(neutron port-create --name rook-${RUN} --binding:host_id=${HOST} ${NETWORKID}) 
 echo "$PORT_INFO"
 PORT_ID=$(echo "$PORT_INFO" | grep "| id"  | awk '{print $4}')
 MAC_ID=$(echo "$PORT_INFO" | grep "mac"  | awk '{print $4}')
 IP_ADDY=$(echo "$PORT_INFO" |  grep "ip_address" | awk '{print $7}'| grep -Eow '[0-9]+.[0-9]+\.+[0-9]+\.[0-9]+')
 PORT_SUB=$(neutron net-list| grep $NETWORKID | awk '{print $7}' | sed -rn 's/.*\/(.*)$/\1/p')
 OVSPLUG="rook-${RUN}"
 ovs-vsctl -- --may-exist add-port br-int ${OVSPLUG} -- set Interface ${OVSPLUG} type=internal -- set Interface ${OVSPLUG} external-ids:iface-status=active -- set Interface ${OVSPLUG} external-ids:attached-mac=${MAC_ID} -- set Interface ${OVSPLUG} external-ids:iface-id=${PORT_ID}
 echo $IP_ADDY
 echo $MAC_ID
 echo $PORT_ID
 echo $PORT_SUB
 sleep 5
 service neutron-openvswitch-agent restart
 ip l s up $OVSPLUG
 ip a a ${IP_ADDY}/${PORT_SUB} dev $OVSPLUG
 
#----------------------- If we are not using Floating IPs ----------------------
elif [ -z "$(ip link | grep -e "$VETH1\s")" ]; then
 echo "#------------------------------------------------------------------------------- "
 echo "Adding a veth"
 echo "#-------------------------------------------------------------------------------"
 ip link add name $VETH1 type veth peer name $VETH2 
 ip a a ${INTERFACE} dev $VETH1
 ip l s up dev $VETH1
 ip l s up dev $VETH2
fi

#
# Glance is erroring out.
#
# BZ 1109890 
#  max database connection issue
#
# IMAGE_ID="f6e00ceb-3c79-41f6-9d09-a163df637328"
# GLANCE=false

if $GLANCE ; then
if [ -z "$(glance image-list | grep -E "${NETPERF_IMG_NAME}")" ]; then
 #----------------------- Import image into Glance ------------------------------
 echo "#------------------------------------------------------------------------------- "
 echo "Importing Netperf image into Glance"
 echo "#-------------------------------------------------------------------------------"
 IMAGE_ID=$(glance image-create --name ${NETPERF_IMG_NAME} --disk-format=qcow2 --container-format=bare < ${NETPERF_IMG} | grep id | awk '{print $4}')
else 
 IMAGE_ID=$(glance image-list | grep -E "${NETPERF_IMG_NAME}" | awk '{print $2}')
fi
fi

if [ -z "$(nova keypair-list | grep "network-testkey")" ]; then 
#----------------------- Security Groups ---------------------------------------
 echo "#------------------------------------------------------------------------------- "
 echo "Adding SSH Key"
 echo "#-------------------------------------------------------------------------------"
 if [ -f $SSHKEY ]; then
  nova keypair-add --pub_key ${SSHKEY} network-testkey
 else 
  echo "ERROR :: SSH public key not found"
  exit 1
 fi
fi

if $SECGROUP; then
if [ -z "$(nova secgroup-list | egrep -E "netperf-networktest")" ] ; then
 echo "#------------------------------------------------------------------------------- "
 echo "Adding Security Rules"
 echo "#-------------------------------------------------------------------------------"
 nova secgroup-create netperf-networktest "network test sec group"
 nova secgroup-add-rule netperf-networktest tcp 22 22 0.0.0.0/0
 nova secgroup-add-rule netperf-networktest icmp -1 -1 0.0.0.0/0
fi
fi

#----------------------- Launch Instances --------------------------------------
echo "#------------------------------------------------------------------------------- "
echo "Launching netperf instnaces"
echo "#-------------------------------------------------------------------------------"
echo "Launching Instances, $(date)"
search_string=""
NETSERVER_HOST="0"
for host_zone in "${ZONE[@]}"
do
  echo "Launching instnace on $host_zone"
  host=$(echo ${host_zone} | awk -F':' '{print $2}')

  if [ "$NETSERVER_HOST" == "0" ] ; then
   NETSERVER_HOST=$host
   register-tool-set --remote=${host} --label=uperf-server 
  else 
   NETCLIENT_HOST=$host
   register-tool-set --remote=${host} --label=uperf-client
  fi
  if $SECGROUP; then
  command_out=$(nova boot --image ${IMAGE_ID} --nic net-id=${NETWORKID} --flavor ${GUEST_SIZE} --availability-zone ${host_zone} netperf-${host_zone} --key_name network-testkey --security_group default,netperf-networktest | egrep "\sid\s" | awk '{print $4}')
  else 
  command_out=$(nova boot --image ${IMAGE_ID} --nic net-id=${NETWORKID} --flavor ${GUEST_SIZE} --availability-zone ${host_zone} netperf-${host_zone} --key_name network-testkey  | egrep "\sid\s" | awk '{print $4}')
  fi
  search_string+="$command_out|"
done


#-------------------------------------------------------------------------------
# Give instances time to get Spawn/Run
# This could vary based on Disk and Network (Glance transfering image)
#-------------------------------------------------------------------------------
echo "#------------------------------------------------------------------------------- "
echo "Waiting for Instances to begin Running"
echo "#-------------------------------------------------------------------------------"
if $DEBUG ; then 
echo "#----------------------- Debug -------------------------------------------------"
echo "Guest Search String :: $search_string"
echo "#-------------------------------------------------------------------------------"
fi
if $TUNNEL ; then
while true; do 
 if ! [ -z "$(nova list | egrep -E "${search_string%?}" | egrep -E "ERROR")" ]; then 
  echo "ERROR :: Netperf guest in error state, Compute node issue"
  if $CLEAN ; then
   cleanup
  fi
  exit 1
 fi
#-------------------------------------------------------------------------------
# This is assuming the SINGLE_TUNNEL_TEST
#-------------------------------------------------------------------------------
 if  [ "$(nova list | egrep -E "${search_string%?}" | egrep -E "Running" | wc -l)" -gt 1 ]; then 
  break
 fi
done

#-------------------------------------------------------------------------------
# Determine the Segmentation ID if not using 
#-------------------------------------------------------------------------------
PORT=0
for ports in `neutron port-list | grep -e "${SUB_SEARCH}" | awk '{print $2}'` ; do 
 if $DEBUG ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "Ports :: $ports"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [[ ! -z $(neutron port-show $ports | grep "device_owner" | grep "compute:nova") ]] ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "Ports :: $ports"
  echo "#-------------------------------------------------------------------------------"
  PORT=$(neutron port-show $ports | grep "mac_address" | awk '{print $4}'); 
 fi 
done;
if [[ -z "${PORT}" ]] ; then
 echo "ERROR :: Unable to determine DHCP Port for Network"
 if $CLEAN ; then
  cleanup
 fi
 exit 0
fi
try=0
if $DEBUG ; then 
 echo "#----------------------- Debug -------------------------------------------------"
 echo "Port :: $PORT"
 echo "#-------------------------------------------------------------------------------"
fi
while true ; do
 FLOW=`ovs-ofctl dump-flows br-tun | grep "${PORT}"`
 IFS=', ' read -a array <<< "$FLOW"
 VLANID_HEX=`echo ${array[9]} | sed 's/vlan_tci=//g' | sed 's/\/.*//g'`
 if $DEBUG ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "VLAN HEX :: $VLANID_HEX"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [[ $(echo $VLANID_HEX | grep -q "dl_dst") -eq 1 ]] ; then 
  continue
 fi 
 VLAN=`printf "%d" ${VLANID_HEX}`
 if $DEBUG ; then
  echo "#----------------------- Debug -------------------------------------------------"
  echo "VLAN :: $VLAN"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [ $VLAN -ne 0 ] ; then
  break
 else 
  sleep 10 
 fi
 if [[ $try -eq 15 ]] ; then 
  echo "ERROR :: Attempting to find the VLAN to use failed..."
  if $CLEAN ; then
   cleanup
  fi
  exit 0
 fi 
 try=$((try+1))
done

if $DEBUG ; then
 echo "Using VLAN :: $VLAN"
fi
fi

if $TUNNEL ; then 
 if ! [ -z "$(ovs-vsctl show | grep "Port \"$VETH2\"")" ] ; then
  ovs-vsctl del-port $VETH2 
 fi
fi
if $TUNNEL ; then 
 VETH_MAC=`ip link | grep -A 1 ${VETH1} | grep link | awk '{ print $2 }'`
 ovs-vsctl add-port br-int ${VETH2} tag=${VLAN}
fi
echo "#------------------------------------------------------------------------------- "
echo "Waiting for instances to come online"
echo "#-------------------------------------------------------------------------------"
INSTANCES=($(nova list | grep -E "${search_string%?}" | egrep -E "Running|spawning" | egrep -oe '([0-9]{1,3}\.[0-9]{1,3}\.[0-9}{1,3}\.[0-9]+)'))
#-------------------------------------------------------------------------------
# Single Tunnel Test -
#       1. Launch a instance on each side of a GRE/VXLAN/STT Tunnel. 
#       2. Make sure there is connectivity from the Host to the guests via Ping
#       3. Attempt to Login to the Guest via SSH 
#-------------------------------------------------------------------------------
if $SINGLE_TUNNEL_TEST ; then 
 ALIVE=0
 NETSERVER=0
 NETCLIENT=0
 for instance in ${INSTANCES[@]}; do 
  TRY=0
  if [ "$NETSERVER" == "0" ] ; then
   NETSERVER=$instance
  else 
   NETCLIENT=$instance
  fi
  while [ "$TRY" -lt "10" ] ; do
   REPLY=`ping $instance -c 5 | grep received | awk '{print $4}'`
   if [ "$REPLY" != "0" ]; then
    let ALIVE=ALIVE+1
    echo "Instance ${instance} is network reachable, $(date)"
    break
   fi
   sleep 5
   let TRY=TRY+1
  done
 done

#-------------------------------------------------------------------------------
# Check to see if instances became pingable
#-------------------------------------------------------------------------------
 if [ $ALIVE -lt 2 ] ; then 
  echo "ERROR :: Unable to reach one of the guests..."
  if $CLEAN ; then
   cleanup
  fi
  exit 1
 fi

 if $DHCP ; then 
 pass=0
 breakloop=0
 while true 
   do 
     if [[ ${pass} -lt 2 ]] ; then 
       pass=0
     fi
     ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} "ip l s mtu ${MTU} dev ${GUEST_VETH}" 
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "ip l s mtu ${MTU} dev ${GUEST_VETH}" 
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     if [ ${pass} -eq 2 ] ; then
       break
     fi
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     if $DEBUG ; then
	echo "pass=$pass , breakloop=$breakloop"
     fi
     if [ $breakloop -eq 10 ] ; then
       echo "Error : unable to set MTU within Guest"
     fi
     breakloop=$((breakloop+1))
 done
 fi 
 
 if $UPERF ; then
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'setenforce 0'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'systemctl stop iptables'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'systemctl stop firewalld'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} '/usr/local/bin/uperf -s ' > /dev/null &
 else
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'netserver ; sleep 4'
 fi
 
 if $DEBUG ; then
  D1=$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'ls')
  echo "#----------------------- Debug -------------------------------------------------"
  echo "SSH Output :: $D1"
  echo "#-------------------------------------------------------------------------------"
 fi

 if $SUPER ; then
  scp $PERFGIT ${NETCLIENT}:
  out=`ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "tar -xzf $PERFGITFILE"`
 fi

 if $PSTAT ; then
  echo "Checking if PStat is running already, if not, start PStat on the Hosts (currently 2 Hosts)"
  if [[ -z $(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t $pstat_host1 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host1"
   ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no $pstat_host1 "/opt/perf-dept/pstat/pstat.sh 1 OSP-${pstat_host1}-${TESTNAME}-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null
 fi
  if [[ -z $(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t $pstat_host2 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host2"
   ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no $pstat_host2 "/opt/perf-dept/pstat/pstat.sh 1 OSP-${pstat_host2}-${TESTNAME}-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null
  fi
 fi

#
# We can add a new param,  $UPERF, and instead of sshing to the guest for netperf, it
# Logs in to configure and run uperf. OK
# We just need to have uperf installed in VM images
# Let me take care of that... If i pull the pbench rpm is that enough? grab uperf rpm as well
# Roger. I will add this to my rhel7 guest. uperf-1.0.4-7.el7.centos.x86_64 from perf-dept pbench repo
# Then we can probably just ssh to the guests: 1 to start uperf server (uperf -s) and the other
# to run pbench_uperf --mode=client --server=<other vm> --test-types=stream (may be a couple more args)
#

 if $UPERF ; then
  TCP_STREAM=false
  UDP_STREAM=false
  echo "Running UPerf"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'setenforce 0'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'systemctl stop iptables'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'systemctl stop firewalld'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "echo 10.16.28.173 pbench.perf.lab.eng.bos.redhat.com >> /etc/hosts"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "echo 10.16.28.171 perf42.perf.lab.eng.bos.redhat.com >> /etc/hosts"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} "echo 10.16.28.173 pbench.perf.lab.eng.bos.redhat.com >> /etc/hosts"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} "echo 10.16.28.171 perf42.perf.lab.eng.bos.redhat.com >> /etc/hosts"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} "echo nameserver 10.16.36.29 > /etc/resolv.conf"
  register-tool-set --remote=${NETCLIENT} 
  register-tool-set --remote=${NETSERVER} 
  if $HIGH_INTERVAL ; then
  for tool in sar pidstat; do
    register-tool --name=${tool} --remote=${NETCLIENT} -- --interval=1
    register-tool --name=${tool} --remote=${NETSERVER} -- --interval=1
  done
  fi
  pbench_uperf --clients=${NETCLIENT} --servers=${NETSERVER} --samples=${SAMPLES} --client-label=uperf-client:${NETCLIENT_HOST} --server-label=uperf-server:${NETSERVER_HOST} --test-types=${TESTS} --protocols=${PROTO} --config=${TESTNAME}

  move-results
  clear-tools
 fi
fi # End SINGLE_TUNNEL_TEST
#----------------------- Cleanup -----------------------------------------------
if $CLEAN ; then
 cleanup
fi