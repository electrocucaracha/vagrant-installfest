#!/bin/bash

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
