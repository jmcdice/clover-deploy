#!/usr/bin/bash
#
# Deploy clover DEV env
# Joey <joey.mcdonald@nokia.com>

# Pull in admin credentials
source /root/keystonerc_admin || exit 255

VM='clover-dev'			 # Name of our VM
key='clover'   			 # Key to create and use
guest_vlan='48'			 # VLAN for guest network
security_group='clover-sec'      # Security group name
guest_network='clover-net'	 # Name of the guest network
public_network='floating'

function verify_creds() {

   # Test to check for admin creds.
   echo -n "Verifying admin credentials: "
   env | grep -q OS_AUTH_URL
   check_exit_code
}

function create_sec_group() {

   echo -n "Creating a security group: "
   neutron security-group-create $security_group &> /dev/null

   # nova secgroup-add-rule $security_group tcp 1 65535 0.0.0.0/0 &> /dev/null

   for port in 22 80 443; do
      neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol \
           tcp --port-range-min $port --port-range-max $port $security_group
   done

   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
      --protocol icmp $security_group  &> /dev/null

   neutron security-group-list | grep -q $security_group
   check_exit_code
}

function create_provider_network() {

   echo -n "Checking for provider network: "
   neutron net-list | grep -q $public_network

   if [ $? != '0' ]; then

      # This is our 'public' network used for either floating IP's and a virtual router
      # or just create VM's with a nic here for direct access (easier).
      net=$(ifconfig br1 | perl -lane 'print $1 if /inet (.*?)\s/' | cut -d'.' -f1-3);
      start="$net.100"
      end="$net.120"
      gateway=$(route -n |grep '^0.0.0.0' |awk '{print $2}')
      mask=$(ifconfig br1|perl -lane 'print $1 if /netmask (.*?)\s/')
      prefix=$(/bin/ipcalc -p $start $mask | awk -F\= '{print $2}')

      echo "Installing ($net.0/$prefix)"

      neutron net-create $public_network --provider:network_type flat \
          --provider:physical_network RegionOne --router:external=True  &> /dev/null

      neutron subnet-create --name ${public_network}-subnet --allocation-pool \
          start=$start,end=$end --gateway $gateway $public_network $net.0/24 \
          --dns_nameservers list=true 8.8.8.8  &> /dev/null

   else
      echo "Ok"
   fi
}

function create_virtual_router() {

   echo -n "Checking for a virtual router: "

   neutron router-list | grep -q router1
   if [ $? != '0' ]; then
      echo "Installing"

      neutron router-create router1  &> /dev/null
      neutron router-gateway-set router1 $public_network &> /dev/null
      neutron router-interface-add router1 subnet1  &> /dev/null
   else
      echo "Ok"
   fi
}

function create_tenant_networks() {

   echo -n "Checking for guest networks: "
   neutron net-list | grep -q $guest_network

   if [ $? != '0' ]; then

      echo "Installing"
      neutron net-create --provider:physical_network RegionOne \
         --provider:network_type vlan --provider:segmentation_id $guest_vlan $guest_network &> /dev/null
      neutron subnet-create $guest_network 10.10.10.0/24 --name subnet1  &> /dev/null

   else
      echo "Ok"
   fi
}

function boot_vm() {

   echo -n "Checking for management VM: "

   nova list --all-tenants | grep -q $VM

   if [ $? != '0' ]; then
      echo "Booting Up"
      # Management VM
      nova boot --image $(nova image-list | grep ubuntu1404 | awk '{print $2}') --flavor m1.large \
          --nic net-id=$(neutron net-list | grep $public_network | awk '{print $2}')  \
          --nic net-id=$(neutron net-list | grep $guest_network | awk '{print $2}')  \
          --key_name $key --security_groups $security_group $VM  
      sleep 10

   else
      echo "Ok" 
   fi
}

function create_flavors() {

   echo -n "Checking for m1.medium flavor: "
   nova flavor-list|grep -q m1.medium
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.medium auto 4096 40 2 &> /dev/null
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.large flavor: "
   nova flavor-list|grep -q m1.large
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.large auto 8192 80 4 &> /dev/null
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.xlarge flavor: "
   nova flavor-list|grep -q m1.xlarge
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.xlarge auto 16384 160 8 &> /dev/null
   else
      echo "Ok"
   fi
}

function create_ssh_key() {

   echo -n "Checking for crypto keys: "
   if [ ! -f /root/.ssh/${key}_id_rsa ]; then
      echo "Installing"
      nova keypair-add $key > /root/.ssh/${key}_id_rsa 
      chmod 400 $key
      nova keypair-show $key |grep ^Public|awk -F': ' '{print $2}' > /root/.ssh/${key}_id_rsa.pub
   else
      echo "Ok"
   fi
}


function wait_for_running() {

   echo -n "Waiting for (${num_of_vms}) VM 'Running' status: "
   sleep 5

   # If we don't get this far, boot failure occured.
   nova list | grep -q juju
   if [ $? -ne 0 ]; then
      echo "Failed to boot VM."
      clean_up
      exit 255
   fi
}

function clean_up() {

   ip=$(get_vm_ip)
   cat ~/.ssh/known_hosts | grep -v $ip > /tmp/known_hosts &> /dev/null
   mv /tmp/known_hosts /root/.ssh/

   for stack in `heat stack-list|grep epdg-stack-00|awk '{print $2}'`
   do
      echo -n "Deleting $stack: "
      heat stack-delete $stack &> /dev/null
      echo "Ok"
   done

   for uuid in `neutron floatingip-list |egrep '10.10.10' |awk '{print $2}'`
   do
      neutron floatingip-delete $uuid
   done

   for uuid in `nova list |egrep "$VM" |awk '{print $2}'`
   do
      nova delete $uuid
   done

   sleep 5

   for router in `neutron router-list|grep router1|awk '{print $2}'`
      do
         for subnet in `neutron router-port-list ${router} -c fixed_ips -f csv | egrep -o '[0-9a-z\-]{36}'`
            do
               neutron router-interface-delete ${router} ${subnet}
            done
         neutron router-gateway-clear ${router}
         neutron router-delete ${router}
      done


   for net in `neutron net-list|egrep "$guest_network|$public_network"|awk '{print $2}'`
   do
      if [ ! -z $net ]; then # Somethimes this isn't set.
         neutron net-delete $net
      fi
   done

   for uuid in `nova secgroup-list | grep $security_group|awk '{print $2}'`
   do
      nova secgroup-delete $uuid &> /dev/null
   done

   for uuid in `nova flavor-list | egrep 'm1.small|m1.medium|m1.large|m1.xlarge' |awk '{print $2}'`
   do 
      nova flavor-delete $uuid &> /dev/null
   done

   rm -rf $key ${key}.pub &> /dev/null

   nova keypair-delete juju-key &> /dev/null
}

function check_exit_code() {

   if [ $? -ne 0 ]; then
      $SMOKE_RES = false
      echo "Failed"
      echo "Running clean up"
      clean_up
      exit 255
   fi
   echo "Success"
}

function get_vm_ip() {

   ip=$(nova list|grep $VM|perl -lane "print \$1 if (/$public_network=(.*?)[;|\s]/)")
   echo $ip
}

function install_clover() {

   echo -n "Installing clover software and OS updates: "
   ip=$(get_vm_ip)

   echo "Using: /root/.ssh/${key}_id_rsa"

   run_cmd_jr="ssh -q -l ubuntu $ip -i /root/.ssh/${key}_id_rsa"
   run_cmd_rt="ssh -q -l root $ip -i /root/.ssh/${key}_id_rsa"

   $run_cmd_jr "sudo sed -n 's/^.*ssh-rsa/ssh-rsa/p' /root/.ssh/authorized_keys > /tmp/authorized_keys" &> /dev/null
   $run_cmd_jr "sudo mv /tmp/authorized_keys /root/.ssh/" &> /dev/null
   $run_cmd_jr "sudo chmod 600 /root/.ssh/authorized_keys" &> /dev/null
   $run_cmd_jr "sudo chown root:root /root/.ssh/authorized_keys" &> /dev/null

   # sudo isn't happy with out this, amateurs.
   $run_cmd_rt "echo '127.0.0.1 $VM' >> /etc/hosts"

   # Ubuntu LTS 14.04 doesn't automatically start a second interface. 
   # Not using this right now but might need it later.

   # echo -n "Starting second network interface on ($ip):"
   $run_cmd_rt "echo -e 'auto eth1\niface eth1 inet dhcp' > /etc/network/interfaces.d/eth1.cfg"
   $run_cmd_rt 'ifup eth1' 
   echo "Ok"

   $run_cmd_rt 'apt-get update'
   $run_cmd_rt 'apt-get install -y python-dev python-pip build-essential libssl-dev libffi-dev python-dev'
   $run_cmd_rt 'pip install ansible==1.9.1'
   $run_cmd_rt 'mkdir -pm 755 ~/.ssh'
   # $run_cmd_rt ''
   # $run_cmd_rt ''

   echo "Ok"
}

function wait_for_running() {

   sleep 15
   ip=$(get_vm_ip)
   echo -n "Waiting for $VM ($ip): "

   ssh -q -l ubuntu -i /root/.ssh/${key}_id_rsa $ip 'date &> /dev/null'
   while test $? -gt 0; do
      sleep 5
      ssh -q -l ubuntu -i /root/.ssh/${key}_id_rsa $ip 'date &> /dev/null'
   done
   echo "Ok"
}



function start_up() {

   start_time=$(date +%s)
   #verify_creds
   #create_sec_group
   #create_ssh_key
   #create_provider_network
   #create_tenant_networks
   #create_flavors
   #create_virtual_router
   #boot_vm
   wait_for_running
   install_clover
   end_time=$(date +%s)
   seconds=$(($end_time - $start_time));
   minutes=$(($seconds / 60))
   
   echo "Deployment completed in $minutes minutes."
}

while [[ $# < 1 ]]; do
   echo ""
   echo "  ./$0 [-c|--create] [-d|--destroy]"
   echo ""
   exit
done

while [[ $# > 0 ]]
do
action="$1"

case $action in
    -d|--destroy)
    DESTROY="yes"
    shift # Completely destory everything.
    ;;
    -c|--create)
    STARTUP="yes"
    shift # Start up the whole virtual cluster.
    ;;


    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

if [ "$DESTROY" == 'yes' ]; then
   while true; do
       echo ""
       read -p "Do you wish to destroy the current install? [y/n]: " yn
       case $yn in
           [Yy]* ) clean_up; exit;;
           [Nn]* ) exit;;
           * ) echo "Please answer yes or no.";;
       esac
   done
fi

if [ "$STARTUP" == 'yes' ]; then
   start_up
   exit
fi

