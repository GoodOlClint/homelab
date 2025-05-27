sudo apt-get update
sudo apt-get -y install git python3, python3-netifaces
sudo git clone https://github.com/alsmith/multicast-relay.git /bin/multicast-relay
sudo rm /bin/multicast-relay/ifFilter.json
sudo sh -c "cat >> /bin/multicast-relay/ifFilter.json" << EOF
{

}
EOF
sudo sh -c "cat >> /etc/logrotate.d/multicast-relay" << EOF
/var/log/multicast-relay.log {
   compress
   daily
   missingok
   postrotate
      systemctl restart multicast-relay
   rotate 7
}
EOF

sudo sh -c "cat >> /etc/systemd/system/multicast-relay.service" << EOF
[Unit]
Description=Multicast Relay
Wants=network.target
After=syslog.target network-online.target

[Service]
Restart=on-failure
RestartSec=10
User=root
WorkingDirectory=/bin/multicast-relay
ExecStart=python3 /bin/multicast-relay/multicast-relay.py --ifFilter /bin/multicast-relay/ifFilter.json --relay 255.255.255.255:7878 --interfaces eth0 eth1 eth2 eth3  --logfile /var/log/multicast-relay.log --verbose --foreground
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start multicast-relay