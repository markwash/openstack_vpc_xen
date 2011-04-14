include ChefVPCToolkit::CloudServersVPC
include ChefVPCToolkit::Util

def mask_to_cidr(mask)
    bitcount = 0
    mask.split('.').each do |octet|
        o = octet.to_i
        bitcount += (o & 1) and (o >>= 1) until o == 0
    end
  return bitcount
end

# By default Xenserver configures xenbr0 with the IP. This function
# moves the IP from the bridge back to eth0 so OpenVPN can use it
def move_xenbr_ip_to_eth0(xenserver_ip, vpn_gw_ip)

    ifconfig_xenbr0=%x{ssh root@#{xenserver_ip} ifconfig xenbr0 | grep 'inet addr'}.chomp
    def_route_xenbr0=%x{ssh root@#{xenserver_ip} ip r | grep default}.chomp

    return false if ifconfig_xenbr0.nil? or ifconfig_xenbr0.empty?

    def_gw=def_route_xenbr0.scan(/default via ([0-9.]*)/).to_s
    ip_addr=ifconfig_xenbr0.scan(/inet addr:([0-9.]*)/).to_s
    bcast=ifconfig_xenbr0.scan(/Bcast:([0-9.]*)/).to_s
    mask=ifconfig_xenbr0.scan(/Mask:([0-9.]*)/).to_s
    cidr=mask_to_cidr(mask)
    out=%x{
ssh root@#{xenserver_ip} bash <<-"EOF_BASH"
cat > /root/move_ip.sh <<-"EOF_CAT"
ip addr del #{ip_addr}/#{cidr} brd #{bcast} scope global dev xenbr0
ip addr add #{ip_addr}/#{cidr} brd #{bcast} scope global dev eth0
brctl delif xenbr0 eth0
route del default gw #{def_gw} xenbr0
route add default gw #{def_gw} eth0
route add -host #{vpn_gw_ip} gw #{def_gw} dev eth0
EOF_CAT
bash /root/move_ip.sh </dev/null &> /dev/null &
EOF_BASH
    }
    return true
    
end

namespace :xenserver do

    desc "Bootstrap a local XenServer install to a server group."
    task :bootstrap do

        group=ServerGroup.fetch(:source => "cache")
        gw_ip=group.vpn_gateway_ip

        xenserver_ip=ENV['XENSERVER_IP']
        raise "Please specify a XENSERVER_IP." if xenserver_ip.nil?
        server_name=ENV['SERVER_NAME']
        raise "Please specify a SERVER_NAME." if server_name.nil?
        pwd=Dir.pwd

        move_xenbr_ip_to_eth0(xenserver_ip, gw_ip)

        # create vPN client keys for the server
        client=group.client(server_name)
        if client.nil? then
            client=Client.create(group, server_name, false)
            client.poll_until_online
        end
        client=Client.fetch(:id => client.id, :source => "remote")
        vpn_interface=client.vpn_network_interfaces[0]

        root_ssh_pub_key=%x{rake ssh cat /root/.ssh/authorized_keys | grep cloud_servers_vpc}.chomp

        out=%x{

# SSH PUBLIC KEY CONFIG
ssh root@#{xenserver_ip} bash <<-"EOF_BASH"
[ -d .ssh ] || mkdir .ssh
chmod 700 .ssh
cat > /root/.ssh/authorized_keys <<-"EOF_CAT"
#{root_ssh_pub_key}
#{Util.load_public_key}
EOF_CAT
chmod 600 /root/.ssh/authorized_keys

# EPEL
cat > /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL <<-"EOF_CAT"
#{IO.read(File.join(File.dirname(__FILE__), "RPM-GPG-KEY-EPEL"))}
EOF_CAT
cat > /etc/yum.repos.d/epel.repo <<-"EOF_CAT"
#{IO.read(File.join(File.dirname(__FILE__), "epel.repo"))}
EOF_CAT

rpm -qi openvpn &> /dev/null || yum install -y openvpn ntp

#OPENVPN CONF
cat > /etc/openvpn/xen1.conf <<-"EOF_CAT"
client
dev tap
proto tcp

remote #{group.vpn_gateway_ip} 1194

resolv-retry infinite
nobind
persist-key
persist-tun

ca ca.crt
cert xen1.crt
key xen1.key

ns-cert-type server

comp-lzo

up ./up.bash
down ./down.bash
up-delay
verb 3
EOF_CAT

cat > /etc/openvpn/xen1.crt <<-"EOF_CAT"
#{vpn_interface.client_cert}
EOF_CAT

cat > /etc/openvpn/xen1.key <<-"EOF_CAT"
#{vpn_interface.client_key}
EOF_CAT
chmod 600 /etc/openvpn/xen1.key

cat > /etc/openvpn/ca.crt <<-"EOF_CAT"
#{vpn_interface.ca_cert}
EOF_CAT

# NOTE: we hard code the broadcast addresses below since this all instances
# of this VPC group will use 172.19.127.255
cat > /etc/openvpn/down.bash <<-"EOF_CAT"
#!/bin/bash
mv /etc/resolv.conf.bak /etc/resolv.conf
/sbin/ip addr del #{client.vpn_network_interfaces[0].vpn_ip_addr}/17 brd 172.19.127.255 scope global dev xenbr0
EOF_CAT
chmod 755 /etc/openvpn/down.bash

cat > /etc/openvpn/up.bash <<-"EOF_CAT"
#!/bin/bash
mv /etc/resolv.conf /etc/resolv.conf.bak
cat > /etc/resolv.conf <<-"EOF_RESOLV_CONF"
search vpc
nameserver 172.19.0.1
EOF_RESOLV_CONF
/sbin/ip addr del #{client.vpn_network_interfaces[0].vpn_ip_addr}/17 brd 172.19.127.255 scope global dev tap0
/sbin/ip addr add #{client.vpn_network_interfaces[0].vpn_ip_addr}/17 brd 172.19.127.255 scope global dev xenbr0
/usr/sbin/brctl addif xenbr0 tap0
EOF_CAT
chmod 755 /etc/openvpn/up.bash

service openvpn start

EOF_BASH
        }
        puts out

    end

end
