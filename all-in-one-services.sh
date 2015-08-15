#!/bin/bash

export token=`openssl rand -hex 10`
export my_nic=`ip route | awk '/192./ { print $3 }'`
export my_ip=`ip addr | awk "/${my_nic}\$/ { sub(/\/24/, \"\","' $2); print $2}'`

rm -rf /etc/yum.repos.d/*.repo
rm -rf /var/cache/yum/

cat << EOF > /etc/yum.repos.d/Installfest.repo
[base]
name=CentOS Base
baseurl=http://$1/mrepo/CentOS-1503-01-x86_64/disc1/
gpgcheck=0

[openstack]
name=OpenStack Kilo Release
baseurl=http://$1/mrepo/centos-openstack-kilo/
gpgcheck=0

[epel]
name=Extra Packages for Enterprise Linux 7
baseurl=http://$1/mrepo/epel/
gpgcheck=0

[rdo]
name=OpenSTack Kilo Release - RDO
baseurl=http://$1/mrepo/openstack-kilo/
gpgcheck=0

[mongo]
name=MongoDB Repository
baseurl=http://$1/mrepo/mongodb/
gpgcheck=0
EOF

yum clean all
yum install -y deltarpm
yum update -y
rm -rf /etc/yum.repos.d/CentOS*.repo

# 1. Install message broker server
yum install -y rabbitmq-server

# 2. Enable and start service
chkconfig rabbitmq-server on
/sbin/service rabbitmq-server start

# 3. Change default guest user password
rabbitmqctl add_user openstack secure
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

# Database

# 1. Install database server
yum install -y mariadb mariadb-server MySQL-python

# 2. Configure remote access
cat <<EOL > /etc/my.cnf
[mysqld]
bind-address = ${my_ip}
default-storage-engine = innodb
innodb_file_per_table
collation-server = utf8_general_ci
init-connect = 'SET NAMES utf8'
character-set-server = utf8
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
symbolic-links=0

[mysqld_safe]
log-error=/var/log/mariadb/mariadb.log
pid-file=/var/run/mariadb/mariadb.pid

!includedir /etc/my.cnf.d
EOL
systemctl enable mariadb.service
systemctl start mariadb.service

echo -e "\nY\nsecure\nsecure\nY\n" | mysql_secure_installation

# NoSQL Database

# 1. Install nosql database server
yum install -y mongodb-org

# 2. Configure remote access
sed -i "s/127.0.0.1/${my_ip}/g" /etc/mongod.conf
echo "smallfiles = true" >> /etc/mongod.conf

# 3. Start services
service mongod start
chkconfig mongod on

sleep 5

# 4. Create ceilometer database
mongo --host all-in-one --eval '
db = db.getSiblingDB("ceilometer");
db.createUser({user: "ceilometer",
pwd: "secure",
roles: [ "readWrite", "dbAdmin" ]})'

# Identity Service

# 1. Install OpenStack Identity Service and dependencies
yum install -y openstack-keystone httpd mod_wsgi python-openstackclient memcached python-memcached

pushd /root/shared/setup
token=`openssl rand -hex 10`
./keystone.sh ${token}

echo "ServerName ${HOSTNAME}">> /etc/httpd/conf/httpd.conf
cat <<EOL > /etc/httpd/conf.d/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
        WSGIProcessGroup keystone-public
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main
        WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
        LogLevel info
    ErrorLogFormat "%{cu}t %M"
        ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined
    </VirtualHost>

    <VirtualHost *:35357>
        WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
        WSGIScriptAlias / /var/www/cgi-bin/keystone/admin
    WSGIApplicationGroup %{GLOBAL}
        WSGIPassAuthorization On
    LogLevel info
        ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/httpd/keystone-error.log
        CustomLog /var/log/httpd/keystone-access.log combined
</VirtualHost>
EOL

# 6. Restart service
systemctl enable memcached.service httpd.service
systemctl start memcached.service httpd.service

./create_default_values.sh ${token}
popd

#yum -y install policycoreutils-python
#semanage port -a -t http_port_t -p tcp 5000
#semanage port -a -t http_port_t -p tcp 35357

# Image services

# 1. Install OpenStack Identity Service and dependencies
yum install -y openstack-glance python-glanceclient

pushd /root/shared/setup
./glance.sh
popd

# 2. Enable and start services
systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

source /root/.bashrc
apt-get install -y python-glanceclient
wget http://$1/mrepo/images/cirros-0.3.3-x86_64-disk.img
glance image-create --name cirros --file cirros-0.3.3-x86_64-disk.img --disk-format qcow2  --container-format bare --is-public True

# Compute controller services

# 1. Install OpenStack Compute Service and dependencies
yum install -y openstack-nova-api openstack-nova-cert openstack-nova-conductor openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler python-novaclient

# 2. Configure Nova Service
crudini --set /etc/nova/nova.conf DEFAULT my_ip ${my_ip}
crudini --set /etc/nova/nova.conf DEFAULT novncproxy_host 0.0.0.0
crudini --set /etc/nova/nova.conf DEFAULT novncproxy_port 6080
crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
crudini --set /etc/nova/nova.conf DEFAULT rabbit_host all-in-one
crudini --set /etc/nova/nova.conf DEFAULT rabbit_password secure
crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone

# 3. Configure Database driver
crudini --set /etc/nova/nova.conf database connection mysql://nova:secure@all-in-one/nova

# 4. Configure Authentication
crudini --set /etc/nova/nova.conf keystone_authtoken identity_uri http://all-in-one:35357
crudini --set /etc/nova/nova.conf keystone_authtoken admin_tenant_name service
crudini --set /etc/nova/nova.conf keystone_authtoken admin_user nova
crudini --set /etc/nova/nova.conf keystone_authtoken admin_password secure

crudini --set /etc/nova/nova.conf paste_deploy flavor keystone

crudini --set /etc/nova/nova.conf glance host image

# 5. Generate tables
su -s /bin/sh -c "nova-manage db sync" nova

# 6. Enable and start services
systemctl enable openstack-nova-api.service openstack-nova-cert.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl start openstack-nova-api.service openstack-nova-cert.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service

# Controller - Networking services

crudini --set /etc/nova/nova.conf DEFAULT network_api_class nova.network.api.API
crudini --set /etc/nova/nova.conf DEFAULT security_group_api nova

systemctl restart openstack-nova-api.service  openstack-nova-scheduler.service openstack-nova-conductor.service

# Compute - Networking services

yum install -y openstack-nova-network

crudini --set /etc/nova/nova.conf DEFAULT network_api_class nova.network.api.API
crudini --set /etc/nova/nova.conf DEFAULT security_group_api nova
crudini --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.libvirt.firewall.IptablesFirewallDriver
crudini --set /etc/nova/nova.conf DEFAULT network_manager nova.network.manager.FlatDHCPManager
crudini --set /etc/nova/nova.conf DEFAULT network_size 254 
crudini --set /etc/nova/nova.conf DEFAULT allow_same_net_traffic False
crudini --set /etc/nova/nova.conf DEFAULT multi_host True
crudini --set /etc/nova/nova.conf DEFAULT send_arp_for_ha True
crudini --set /etc/nova/nova.conf DEFAULT share_dhcp_address True
crudini --set /etc/nova/nova.conf DEFAULT force_dhcp_release True
crudini --set /etc/nova/nova.conf DEFAULT flat_network_bridge br100
crudini --set /etc/nova/nova.conf DEFAULT flat_interface eth0
crudini --set /etc/nova/nova.conf DEFAULT public_interface eth0

systemctl enable openstack-nova-network.service
systemctl start openstack-nova-network.service

nova network-create demo-net --bridge br100 --fixed-range-v4 203.0.113.24/29

# OpenStack Dashboard

# 1. Install OpenStack Compute Service and dependencies
yum install -y openstack-dashboard httpd mod_wsgi memcached python-memcached

# 2. Configure settings
sed -i "s/OPENSTACK_HOST = \"127.0.0.1\"/OPENSTACK_HOST = \"all-in-one\"/g" /etc/openstack-dashboard/local_settings

# 3. Configure memcached
sed -i "s/'django.core.cache.backends.locmem.LocMemCache'/'django.core.cache.backends.memcached.MemcachedCache',\n        'LOCATION': '127.0.0.1:11211'/g" /etc/openstack-dashboard/local_settings

# 4. Configure SELinux to permit the web server to connect
setsebool -P httpd_can_network_connect on

# Block storage service

# 4. Configure SELinux to permit the web server to connect
setsebool -P httpd_can_network_connect on

# 5. Solve the CSS issue
chown -R apache:apache /usr/share/openstack-dashboard/static

# 6. Enable services
systemctl enable httpd.service memcached.service
systemctl start httpd.service memcached.service

# 1. Install OpenStack Block Storage Service and dependencies
yum install -y openstack-cinder python-cinderclient python-oslo-db

# 1.1 Workaround for cinder-api dependency
yum install -y python-keystonemiddleware

# 2. Configure Database driver
crudini --set /etc/cinder/cinder.conf database connection  mysql://cinder:secure@all-in-one/cinder

# 3. Configure message broker service
crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_host all-in-one
crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_password secure

# 4. Configure Identity Service
crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://all-in-one:5000/v2.0
crudini --set /etc/cinder/cinder.conf keystone_authtoken identity_uri http://all-in-one:35357
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_tenant_name service
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_user cinder
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_password secure

crudini --set /etc/cinder/cinder.conf DEFAULT my_ip ${my_ip}

# 5. Generate tables
su -s /bin/sh -c "cinder-manage db sync" cinder

# 6. Enable and start services
systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service

# Telemetry service

# 1. Install OpenStack Telemetry Service and dependencies
yum install -y openstack-ceilometer-api openstack-ceilometer-collector openstack-ceilometer-notification openstack-ceilometer-central openstack-ceilometer-alarm python-ceilometerclient

# 2. Configure database connection
crudini --set /etc/ceilometer/ceilometer.conf database connection mongodb://ceilometer:secure@all-in-one:27017/ceilometer

# 3. Configure message broker connection
crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_host all-in-one
crudini --set /etc/ceilometer/ceilometer.conf rabbit_password secure
crudini --set /etc/ceilometer/ceilometer.conf auth_strategy keystone

# 4. Configure authentication
crudini --set /etc/ceilometer/ceilometer.conf DEFAULT auth_strategy keystone
crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken auth_uri http://all-in-one:5000/v2.0
crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken identity_uri http://all-in-one:35357
crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_tenant_name service
crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_user ceilometer
crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_password secure

# 5 Configure service credentials
crudini --set /etc/ceilometer/ceilometer.conf service_credentials os_auth_url http://all-in-one:35357
crudini --set /etc/ceilometer/ceilometer.conf service_credentials os_username ceilometer
crudini --set /etc/ceilometer/ceilometer.conf service_credentials os_tenant_name service
crudini --set /etc/ceilometer/ceilometer.conf service_credentials os_password secure

token=`openssl rand -hex 10`
crudini --set /etc/ceilometer/ceilometer.conf publisher metering_secret ${token}

systemctl enable openstack-ceilometer-api.service openstack-ceilometer-notification.service  openstack-ceilometer-central.service openstack-ceilometer-collector.service openstack-ceilometer-alarm-evaluator.service openstack-ceilometer-alarm-notifier.service
systemctl start openstack-ceilometer-api.service openstack-ceilometer-notification.service openstack-ceilometer-central.service openstack-ceilometer-collector.service openstack-ceilometer-alarm-evaluator.service openstack-ceilometer-alarm-notifier.service

# Compute Service

# 1. Install OpenStack Compute Service and dependencies
yum install -y openstack-nova-compute sysfsutils

# 2. Configure message broker service
crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
crudini --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_host all-in-one
crudini --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid openstack
crudini --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password secure

# 4. Configure Identity Service
crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
crudini --set /etc/nova/nova.conf keystone_authtoken auth_uri http://all-in-one:5000
crudini --set /etc/nova/nova.conf keystone_authtoken auth_url http://all-in-one:35357
crudini --set /etc/nova/nova.conf keystone_authtoken auth_plugin password
crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_id default
crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_id default 
crudini --set /etc/nova/nova.conf keystone_authtoken project_name service
crudini --set /etc/nova/nova.conf keystone_authtoken username nova
crudini --set /etc/nova/nova.conf keystone_authtoken password secure

crudini --set /etc/nova/nova.conf DEFAULT my_ip ${my_ip}

# 3. Configure VNC Server
crudini --set /etc/nova/nova.conf DEFAULT vnc_enabled True
crudini --set /etc/nova/nova.conf DEFAULT vncserver_listen 0.0.0.0
crudini --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address 127.0.0.1
crudini --set /etc/nova/nova.conf DEFAULT novncproxy_base_url http://all-in-one:6080/vnc_auto.html

# 5. Configure Image Service
crudini --set /etc/nova/nova.conf glance host all-in-one

crudini --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp

# 6. Use KVM or QEMU
supports_hardware_acceleration=`egrep -c '(vmx|svm)' /proc/cpuinfo`
if [ $supports_hardware_acceleration -eq 0 ]; then
  crudini --set /etc/nova/nova.conf libvirt virt_type qemu
fi

# 7. Restart services
systemctl enable libvirtd.service openstack-nova-compute.service
systemctl start libvirtd.service
systemctl start openstack-nova-compute.service

# Logical Volume

# 1. Install Logical Volume Manager
yum install -y lvm2

# 1.1 Enable the LVM services
systemctl enable lvm2-lvmetad.service
systemctl start lvm2-lvmetad.service

# 2. Create a partition based on other partition
cat <<EOL > sdb.layout
# partition table of /dev/sdb
unit: sectors

/dev/sdb1 : start=     2048, size= 83884032, Id=83, bootable
/dev/sdb2 : start=        0, size=        0, Id= 0
/dev/sdb3 : start=        0, size=        0, Id= 0
/dev/sdb4 : start=        0, size=        0, Id= 0
EOL
sfdisk /dev/sdb < sdb.layout

# 3. Create the LVM physical volume /dev/sdb1
pvcreate /dev/sdb1

# 4. Create the LVM volume group cinder-volumes
vgcreate cinder-volumes /dev/sdb1

# 5. Add a filter that accepts the /dev/sdb device and rejects all other devices
sed -i "s/filter = \[ \"a\/.*\/\"/filter = \[ \"a\/sdb\/\", \"r\/.\*\/\"/g" /etc/lvm/lvm.conf

# 1. Install OpenStack Compute Service and dependencies
yum install -y openstack-cinder targetcli python-oslo-db MySQL-python

# 2. Configure Database driver
crudini --set /etc/cinder/cinder.conf database connection  mysql://cinder:secure@all-in-one/cinder

# 3. Configure message broker service
crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_host all-in-one
crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_password secure

# 4. Configure Identity Service
crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://all-in-one:5000/v2.0
crudini --set /etc/cinder/cinder.conf keystone_authtoken identity_uri http://all-in-one:35357
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_tenant_name service
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_user cinder
crudini --set /etc/cinder/cinder.conf keystone_authtoken admin_password secure

crudini --set /etc/cinder/cinder.conf DEFAULT my_ip ${my_ip}
crudini --set /etc/cinder/cinder.conf DEFAULT glance_host all-in-one
#crudini --set /etc/cinder/cinder.conf DEFAULT iscsi_helper lioadm
crudini --set /etc/cinder/cinder.conf DEFAULT iscsi_helper tgtadm

# 5. Start services
systemctl enable openstack-cinder-volume.service target.service
systemctl start openstack-cinder-volume.service target.service
