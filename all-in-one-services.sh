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
yum install -y deltarpm crudini
yum update -y
rm -rf /etc/yum.repos.d/CentOS*.repo

# 1. Install message broker server
yum install -y rabbitmq-server

# 2. Enable and start service
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service

# 3. Change default guest user password
rabbitmqctl add_user openstack secure
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

# Database

# 1. Install database server
yum install -y mariadb mariadb-server MySQL-python

# 2. Configure remote access
cat <<EOL > /etc/my.cnf
[mysqld]
bind-address = 0.0.0.0
default-storage-engine = innodb
innodb_file_per_table
collation-server = utf8_general_ci
init-connect = 'SET NAMES utf8'
character-set-server = utf8
EOL
systemctl enable mariadb.service
systemctl start mariadb.service

echo -e "\nY\nsecure\nsecure\nY\n" | mysql_secure_installation

# Identity Service

mysql -uroot -psecure -e "CREATE DATABASE keystone;"
mysql -uroot -psecure -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'all-in-one' IDENTIFIED BY 'secure';"

# 1. Install OpenStack Identity Service and dependencies
yum install -y openstack-keystone httpd mod_wsgi python-openstackclient memcached python-memcached

# 2. Configure Database driver
crudini --set /etc/keystone/keystone.conf database connection mysql://keystone:secure@all-in-one/keystone
crudini --set /etc/keystone/keystone.conf revoke driver keystone.contrib.revoke.backends.sql.Revoke

# 2.1 Configure Memcached
crudini --set /etc/keystone/keystone.conf memcache servers localhost:11211
crudini --set /etc/keystone/keystone.conf memcache provider keystone.token.providers.uuid.Provider
crudini --set /etc/keystone/keystone.conf memcache driver keystone.token.persistence.backends.memcache.Token

# 3. Generate tables
su -s /bin/sh -c "keystone-manage db_sync" keystone

mkdir -p /var/www/cgi-bin/keystone
wget -O /var/www/cgi-bin/keystone/main http://$1/mrepo/scripts
cp /var/www/cgi-bin/keystone/main /var/www/cgi-bin/keystone/admin

chown -R keystone:keystone /var/www/cgi-bin/keystone
chmod 755 /var/www/cgi-bin/keystone/*

# 5. Configurate authorization token
crudini --set /etc/keystone/keystone.conf DEFAULT admin_token ${token}

echo "ServerName all-in-one">> /etc/httpd/conf/httpd.conf
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

export OS_TOKEN=${token}
export OS_URL=http://all-in-one:35357/v2.0

openstack service create \
  --name keystone --description "OpenStack Identity" identity

openstack endpoint create \
  --publicurl http://all-in-one:5000/v2.0 \
  --internalurl http://all-in-one:5000/v2.0 \
  --adminurl http://all-in-one:35357/v2.0 \
  --region regionOne \
  identity

openstack project create --description "Admin Project" admin
openstack user create --password "secure" admin
openstack role create admin
openstack role add --project admin --user admin admin
openstack project create --description "Service Project" service
openstack project create --description "Demo Project" demo

openstack user create --password "secure" demo
openstack role create user
openstack role add --project demo --user demo user

unset OS_TOKEN OS_URL
export OS_VOLUME_API_VERSION=2
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=secure
export OS_AUTH_URL=http://all-in-one:35357/v3

# Image services

mysql -uroot -psecure -e "CREATE DATABASE glance;"
mysql -uroot -psecure -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'all-in-one' IDENTIFIED BY 'secure';"

# 1. Install OpenStack Identity Service and dependencies
yum install -y openstack-glance python-glanceclient

# 1. User, service and endpoint creation
source /root/admin-openrc.sh
openstack user create glance --password=secure --email=glance@example.com
openstack role add admin --user=glance --project=service
openstack service create image --name=glance --description="OpenStack Image Service"
openstack endpoint create \
  --publicurl=http://all-in-one:9292 \
  --internalurl=http://all-in-one:9292 \
  --adminurl=http://all-in-one:9292 \
  --region regionOne \
  image

# 2. Configure api service
crudini --set /etc/glance/glance-api.conf database connection mysql://glance:secure@all-in-one/glance

crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_uri http://all-in-one:5000
crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://all-in-one:35357
crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_plugin password
crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_id default
crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_id default
crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name service
crudini --set /etc/glance/glance-api.conf keystone_authtoken username glance
crudini --set /etc/glance/glance-api.conf keystone_authtoken password secure
crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone

crudini --set /etc/glance/glance-api.conf glance_store default_store file
crudini --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/

crudini --set /etc/glance/glance-api.conf DEFAULT notification_driver noop

# 3. Configure registry service
crudini --set /etc/glance/glance-registry.conf database connection  mysql://glance:secure@all-in-one/glance

crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri http://all-in-one:5000
crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_url http://all-in-one:35357
crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_plugin password
crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_id default
crudini --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_id default
crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
crudini --set /etc/glance/glance-registry.conf keystone_authtoken username glance
crudini --set /etc/glance/glance-registry.conf keystone_authtoken password secure
crudini --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

crudini --set /etc/glance/glance-registry.conf DEFAULT notification_driver noop

# 4. Generate tables
su -s /bin/sh -c "glance-manage db_sync" glance

# 2. Enable and start services
systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

apt-get install -y python-glanceclient
wget http://$1/mrepo/images/cirros-0.3.3-x86_64-disk.img
glance image-create --name cirros --file cirros-0.3.3-x86_64-disk.img --disk-format qcow2  --container-format bare --is-public True

