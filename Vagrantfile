# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure(2) do |config|
  config.vm.box = "chef/centos-7.0"
  config.vm.hostname = 'all-in-one'
  config.vm.network :private_network, ip: '192.168.50.2'
  config.vm.network :forwarded_port, guest: 5672, host: 5672
  config.vm.network :forwarded_port, guest: 15672, host: 15672
  config.vm.network :forwarded_port, guest: 3306, host: 3306
  config.vm.network :forwarded_port, guest: 27017, host: 27017
  config.vm.network :forwarded_port, guest: 5000, host: 5000
  config.vm.network :forwarded_port, guest: 35357, host: 35357
  config.vm.network :forwarded_port, guest: 9292, host: 9292
  config.vm.network :forwarded_port, guest: 8774, host: 8774
  config.vm.network :forwarded_port, guest: 8776, host: 8776
  config.vm.network :forwarded_port, guest: 8777, host: 8777
  config.vm.network :forwarded_port, guest: 8080, host: 8080
  config.vm.network :forwarded_port, guest: 8000, host: 8000
  config.vm.network :forwarded_port, guest: 8004, host: 8004
  config.vm.network :forwarded_port, guest: 80, host: 8880
  config.vm.network :forwarded_port, guest: 6080, host: 6080
  config.vm.provider "virtualbox" do |v|
    v.customize ["modifyvm", :id, "--memory", 4 * 1024]
    v.customize ['createhd', '--filename', 'block-storage.vdi', '--size', 50 * 1024]
    v.customize ['createhd', '--filename', 'object-storage.vdi', '--size', 50 * 1024]
    v.customize ['storageattach', :id, '--storagectl', 'IDE Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', 'block-storage.vdi']
    v.customize ['storageattach', :id, '--storagectl', 'IDE Controller', '--port', 1, '--device', 1, '--type', 'hdd', '--medium', 'object-storage.vdi']
  end

  config.vm.provision "shell" do |s|
    s.path = "postinstall.sh"
    #s.path = "all-in-one-services.sh"
    s.args = ["192.168.1.10"]
  end
end
