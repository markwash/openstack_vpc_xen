include ChefVPCToolkit::CloudServersVPC
include ChefVPCToolkit::Util

namespace :xenserver do

    desc "Bootstrap a local XenServer install to a server group."
    task :bootstrap do

        group=ServerGroup.fetch(:source => "cache")
		gw_ip=group.vpn_gateway_ip

        xenserver_ip=ENV['XENSERVER_IP']
        raise "Please specify a XENSERVER_IP." if xenserver_ip.nil?
        pwd=Dir.pwd

        client=Client.create(group, 'xenserver', false)
        client.poll_until_online
        client=Client.fetch(:id => client.id, :source => "remote")
        vpn_interface=client.vpn_network_interfaces[0]
        puts client.inspect

        out=%x{

# SSH PUBLIC KEY CONFIG
ssh root@#{xenserver_ip} bash <<-"BASH_EOF"
[ -d .ssh ] || mkdir .ssh
chmod 700 .ssh
cat > /root/.ssh/authorized_keys <<-"EOF_CAT"
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

BASH_EOF
        }
        puts out

    end

end
