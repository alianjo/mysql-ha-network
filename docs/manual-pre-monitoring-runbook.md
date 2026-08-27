# Manual Deployment Runbook: Before Monitoring

This is the manual, SSH-based deployment record for the isolated four-server lab.
It covers every server component installed before monitoring: Ubuntu baseline,
WireGuard, FRR/OSPF/BFD, stable loopbacks, and MySQL GTID replication.

Do not apply these commands to the previous infrastructure. Run them as root on
only the four hosts below. Monitoring, exporters, Prometheus, Grafana,
Alertmanager, Loki, and Alloy are deliberately excluded.

## 1. Lab topology

| Role | Host | Public IP | Stable service address |
| --- | --- | --- | --- |
| MySQL primary | mysql1 | 37.32.5.124 | 10.255.1.1/32 |
| Preferred transit router | mywireguard1 | 37.32.4.177 | none |
| MySQL replica | mysql2 | 95.38.161.103 | 10.255.2.1/32 |
| Backup transit router | mywireguard2 | 188.121.121.59 | none |

~~~text
                       WG-1: preferred, OSPF cost 10 per link
              mysql1 ---- mywireguard1 ---- mysql2
                |                                  |
                +------- mywireguard2 -------------+
                       WG-2: backup, OSPF cost 100 per link
~~~

| Path | Left endpoint | Right endpoint | UDP port |
| --- | --- | --- | ---: |
| WG-1 first link | mysql1 wg1a, 10.10.1.1/30 | mywireguard1 wg1a, 10.10.1.2/30 | 51811 |
| WG-1 second link | mywireguard1 wg1b, 10.10.1.5/30 | mysql2 wg1b, 10.10.1.6/30 | 51812 |
| WG-2 first link | mysql1 wg2a, 10.10.2.1/30 | mywireguard2 wg2a, 10.10.2.2/30 | 51821 |
| WG-2 second link | mywireguard2 wg2b, 10.10.2.5/30 | mysql2 wg2b, 10.10.2.6/30 | 51822 |

The MySQL replication connection uses 10.255.1.1, not a public address or
WireGuard transit address. WireGuard uses Table = off, so FRR/OSPF owns the
end-to-end service routes.

## 2. Common Ubuntu baseline

Run this on mysql1, mywireguard1, mysql2, and mywireguard2.

~~~bash
apt-get update
apt-get install -y ca-certificates curl jq python3 python3-pip nftables wireguard-tools iputils-ping netcat-openbsd

timedatectl set-timezone UTC

install -d -o root -g root -m 0755 /etc/mysql-ha-network /var/lib/mysql-ha-network
install -d -o root -g root -m 0750 /var/log/mysql-ha-network

tee /etc/sysctl.d/99-sre-ha-networking.conf >/dev/null <<'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

sysctl --system

install -d -o root -g root -m 0755 /etc/nftables.d

tee /etc/nftables.d/00-sre-base.nft >/dev/null <<'EOF'
table inet sre_base {
}
EOF

tee /etc/nftables.conf >/dev/null <<'EOF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.nft"
EOF

nft -c -f /etc/nftables.conf
systemctl enable --now nftables
~~~

The nftables configuration above is intentionally non-restrictive: it creates
only an empty table and does not add an input, output, or forward policy.

Enable forwarding only on the two transit routers:

~~~bash
# Run only on mywireguard1 and mywireguard2.
tee /etc/sysctl.d/99-sre-ha-router.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
EOF

sysctl --system
~~~

Verify each host:

~~~bash
echo "HOST: $(hostname)"
echo "TIMEZONE: $(timedatectl show --property=Timezone --value)"
wg --version
sysctl net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv4.ip_forward
systemctl is-enabled nftables
systemctl is-active nftables
nft list ruleset
~~~

Expected value of net.ipv4.ip_forward: 0 on mysql1 and mysql2; 1 on
mywireguard1 and mywireguard2.

## 3. WireGuard

### 3.1 Generate keys locally

Private keys never leave their host. The umask is confined to a subshell, so it
does not affect the permissions of later MySQL configuration files.

~~~bash
# Run this on each host, using the listed interface names.
install -d -o root -g root -m 0700 /etc/wireguard /etc/wireguard/keys

for interface in <LOCAL_INTERFACE_1> <LOCAL_INTERFACE_2>; do
  if [ ! -s /etc/wireguard/keys/$interface.private ]; then
    ( umask 077; wg genkey > /etc/wireguard/keys/$interface.private )
  fi
  wg pubkey < /etc/wireguard/keys/$interface.private > /etc/wireguard/keys/$interface.public
done

chown root:root /etc/wireguard/keys/*
chmod 0600 /etc/wireguard/keys/*.private
chmod 0644 /etc/wireguard/keys/*.public

for key in /etc/wireguard/keys/*.public; do
  printf '%s %s: ' "$(hostname)" "$(basename "$key" .public)"
  cat "$key"
done
~~~

Use these values for the two placeholders in the preceding command:

| Host | Local interfaces |
| --- | --- |
| mysql1 | wg1a wg2a |
| mywireguard1 | wg1a wg1b |
| mysql2 | wg1b wg2b |
| mywireguard2 | wg2a wg2b |

Record the resulting public keys. A peer key is associated with an interface,
not merely with a host. Never print or copy a private key. Generate fresh keys
for a future deployment; do not reuse this lab's key material.

### 3.2 Install WireGuard configurations

On each host, define this shell function once. It writes one interface
configuration. Replace every PUBLIC_KEY placeholder in the invocation commands
with the public key collected from the remote peer's matching interface.

~~~bash
write_wg_config() {
  interface=$1
  address=$2
  listen_port=$3
  peer_public_key=$4
  endpoint=$5
  peer_transit_ip=$6
  peer_service_ip=$7

  tee /etc/wireguard/$interface.conf >/dev/null <<EOF
[Interface]
Address = $address
ListenPort = $listen_port
Table = off
PostUp = /usr/bin/wg set %i private-key /etc/wireguard/keys/$interface.private

[Peer]
PublicKey = $peer_public_key
Endpoint = $endpoint
AllowedIPs = $peer_transit_ip/32, $peer_service_ip/32, 224.0.0.5/32, 224.0.0.6/32
PersistentKeepalive = 25
EOF

  chown root:root /etc/wireguard/$interface.conf
  chmod 0600 /etc/wireguard/$interface.conf
  wg-quick strip /etc/wireguard/$interface.conf >/dev/null
}
~~~

Run the appropriate two commands on each host.

~~~bash
# mysql1
write_wg_config wg1a 10.10.1.1/30 51811 <MYWIREGUARD1_WG1A_PUBLIC_KEY> 37.32.4.177:51811 10.10.1.2 10.255.2.1
write_wg_config wg2a 10.10.2.1/30 51821 <MYWIREGUARD2_WG2A_PUBLIC_KEY> 188.121.121.59:51821 10.10.2.2 10.255.2.1
systemctl enable --now wg-quick@wg1a wg-quick@wg2a
~~~

~~~bash
# mywireguard1
write_wg_config wg1a 10.10.1.2/30 51811 <MYSQL1_WG1A_PUBLIC_KEY> 37.32.5.124:51811 10.10.1.1 10.255.1.1
write_wg_config wg1b 10.10.1.5/30 51812 <MYSQL2_WG1B_PUBLIC_KEY> 95.38.161.103:51812 10.10.1.6 10.255.2.1
systemctl enable --now wg-quick@wg1a wg-quick@wg1b
~~~

~~~bash
# mysql2
write_wg_config wg1b 10.10.1.6/30 51812 <MYWIREGUARD1_WG1B_PUBLIC_KEY> 37.32.4.177:51812 10.10.1.5 10.255.1.1
write_wg_config wg2b 10.10.2.6/30 51822 <MYWIREGUARD2_WG2B_PUBLIC_KEY> 188.121.121.59:51822 10.10.2.5 10.255.1.1
systemctl enable --now wg-quick@wg1b wg-quick@wg2b
~~~

~~~bash
# mywireguard2
write_wg_config wg2a 10.10.2.2/30 51821 <MYSQL1_WG2A_PUBLIC_KEY> 37.32.5.124:51821 10.10.2.1 10.255.1.1
write_wg_config wg2b 10.10.2.5/30 51822 <MYSQL2_WG2B_PUBLIC_KEY> 95.38.161.103:51822 10.10.2.6 10.255.2.1
systemctl enable --now wg-quick@wg2a wg-quick@wg2b
~~~

The AllowedIPs values serve two purposes: WireGuard peer selection/source
validation and OSPF multicast delivery. They do not insert service routes,
because Table = off prevents wg-quick route installation.

### 3.3 Verify direct links

~~~bash
# mysql1
ping -I wg1a -c 3 10.10.1.2
ping -I wg2a -c 3 10.10.2.2
wg show

# mywireguard1
ping -I wg1b -c 3 10.10.1.6
wg show

# mywireguard2
ping -I wg2b -c 3 10.10.2.6
wg show

# mysql2
ping -I wg1b -c 3 10.10.1.5
ping -I wg2b -c 3 10.10.2.5
wg show
~~~

At this point each direct peer ping and every latest handshake must succeed.
End-to-end 10.255.x.x routing is not expected until FRR is configured.

## 4. FRR, OSPF, BFD, and stable loopbacks

### 4.1 Install FRR on all four hosts

~~~bash
apt-get update
apt-get install -y frr frr-pythontools

sed -ri 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
sed -ri 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
sed -ri 's/^bfdd=.*/bfdd=yes/' /etc/frr/daemons
sed -ri 's/^vtysh_enable=.*/vtysh_enable=yes/' /etc/frr/daemons
~~~

### 4.2 Persist stable MySQL loopbacks

~~~bash
# Run on mysql1.
tee /etc/systemd/system/sre-mysql-loopback.service >/dev/null <<'EOF'
[Unit]
Description=HA stable MySQL service loopback
After=network-online.target
Wants=network-online.target
Before=frr.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env ip address replace 10.255.1.1/32 dev lo
ExecStop=-/usr/bin/env ip address del 10.255.1.1/32 dev lo

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sre-mysql-loopback.service
~~~

~~~bash
# Run on mysql2.
tee /etc/systemd/system/sre-mysql-loopback.service >/dev/null <<'EOF'
[Unit]
Description=HA stable MySQL service loopback
After=network-online.target
Wants=network-online.target
Before=frr.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env ip address replace 10.255.2.1/32 dev lo
ExecStop=-/usr/bin/env ip address del 10.255.2.1/32 dev lo

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sre-mysql-loopback.service
~~~

### 4.3 Configure FRR on each host

BFD uses 500 ms transmit/receive intervals with a multiplier of 3. Its
intended adjacent-link detection time is about 1.5 seconds. OSPF hello/dead
timers remain 10/40 seconds; BFD provides fast failure detection.

~~~bash
# mysql1
tee /etc/frr/frr.conf >/dev/null <<'EOF'
frr defaults traditional
hostname mysql1
service integrated-vtysh-config
log syslog informational
!
bfd
 profile SRE_OSPF
  detect-multiplier 3
  receive-interval 500
  transmit-interval 500
 !
!
interface wg1a
 description WG1 to mywireguard1
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 10
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface wg2a
 description WG2 to mywireguard2
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 100
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface lo
 ip ospf area 0.0.0.0
!
router ospf
 ospf router-id 10.254.0.1
 passive-interface default
 no passive-interface wg1a
 no passive-interface wg2a
 network 10.255.1.1/32 area 0.0.0.0
!
line vty
!
EOF
~~~

~~~bash
# mywireguard1
tee /etc/frr/frr.conf >/dev/null <<'EOF'
frr defaults traditional
hostname mywireguard1
service integrated-vtysh-config
log syslog informational
!
bfd
 profile SRE_OSPF
  detect-multiplier 3
  receive-interval 500
  transmit-interval 500
 !
!
interface wg1a
 description WG1 to mysql1
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 10
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface wg1b
 description WG1 to mysql2
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 10
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
router ospf
 ospf router-id 10.254.0.2
 passive-interface default
 no passive-interface wg1a
 no passive-interface wg1b
!
line vty
!
EOF
~~~

~~~bash
# mywireguard2
tee /etc/frr/frr.conf >/dev/null <<'EOF'
frr defaults traditional
hostname mywireguard2
service integrated-vtysh-config
log syslog informational
!
bfd
 profile SRE_OSPF
  detect-multiplier 3
  receive-interval 500
  transmit-interval 500
 !
!
interface wg2a
 description WG2 to mysql1
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 100
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface wg2b
 description WG2 to mysql2
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 100
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
router ospf
 ospf router-id 10.254.0.3
 passive-interface default
 no passive-interface wg2a
 no passive-interface wg2b
!
line vty
!
EOF
~~~

~~~bash
# mysql2
tee /etc/frr/frr.conf >/dev/null <<'EOF'
frr defaults traditional
hostname mysql2
service integrated-vtysh-config
log syslog informational
!
bfd
 profile SRE_OSPF
  detect-multiplier 3
  receive-interval 500
  transmit-interval 500
 !
!
interface wg1b
 description WG1 to mywireguard1
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 10
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface wg2b
 description WG2 to mywireguard2
 ip ospf area 0.0.0.0
 ip ospf network point-to-point
 ip ospf cost 100
 ip ospf hello-interval 10
 ip ospf dead-interval 40
 ip ospf bfd
 ip ospf bfd profile SRE_OSPF
!
interface lo
 ip ospf area 0.0.0.0
!
router ospf
 ospf router-id 10.254.0.4
 passive-interface default
 no passive-interface wg1b
 no passive-interface wg2b
 network 10.255.2.1/32 area 0.0.0.0
!
line vty
!
EOF
~~~

After writing the local configuration, run these commands on every one of the
four hosts:

~~~bash
chown frr:frr /etc/frr/frr.conf
chmod 0640 /etc/frr/frr.conf
vtysh -C -f /etc/frr/frr.conf
systemctl enable --now frr
systemctl is-active frr
~~~

### 4.4 Verify routing and test failover

Run on mysql1:

~~~bash
vtysh -c 'show ip ospf neighbor'
vtysh -c 'show bfd peers'
vtysh -c 'show ip route 10.255.2.1'
ip route get 10.255.2.1 from 10.255.1.1
ping -I 10.255.1.1 -c 3 10.255.2.1
~~~

The normal route is expected to use WG-1:

~~~text
10.255.2.1 via 10.10.1.2 dev wg1a proto ospf metric 20
~~~

Run the analogous commands on mysql2, targeting 10.255.1.1. Its normal route
uses wg1b.

To test automatic backup-path selection, keep this running on mysql1:

~~~bash
watch -n 0.5 'ip route get 10.255.2.1 from 10.255.1.1'
~~~

Then, in a second session on mywireguard1, simulate preferred-router failure:

~~~bash
systemctl stop frr
~~~

After convergence, mysql1 must use the independent backup path:

~~~text
10.255.2.1 via 10.10.2.2 dev wg2a proto ospf metric 200
~~~

Restore it after the test:

~~~bash
# Run on mywireguard1.
systemctl start frr
systemctl is-active frr
~~~

A direct preferred-link test is also possible. Restore it as soon as the route
has converged:

~~~bash
# Run on mysql1.
systemctl stop wg-quick@wg1a
systemctl start wg-quick@wg1a
~~~

## 5. MySQL GTID primary/replica configuration

GTID requires a safe state transition. First enable it dynamically in the
required order, then write the final configuration file. The configuration file
must be readable by the mysql service account before restarting MySQL.

### 5.1 Install and stage mysql1

~~~bash
# Run on mysql1.
apt-get update
apt-get install -y mysql-server

tee /etc/mysql/mysql.conf.d/99-sre-ha.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 10.255.1.1
server-id = 1
log_bin = mysql-bin
binlog_format = ROW
EOF

chown root:root /etc/mysql/mysql.conf.d/99-sre-ha.cnf
chmod 0644 /etc/mysql/mysql.conf.d/99-sre-ha.cnf
runuser -u mysql -- test -r /etc/mysql/mysql.conf.d/99-sre-ha.cnf

systemctl enable mysql
systemctl restart mysql
systemctl is-active mysql
ss -lntp | grep ':3306'
~~~

Enable GTID. Run the final command only when the anonymous transaction count is
zero:

~~~bash
# Run on mysql1.
mysql <<'SQL'
SET GLOBAL enforce_gtid_consistency = ON;
SET GLOBAL gtid_mode = OFF_PERMISSIVE;
SET GLOBAL gtid_mode = ON_PERMISSIVE;
SQL

mysql -e "SHOW STATUS LIKE 'ONGOING_ANONYMOUS_TRANSACTION_COUNT';"

# Continue only if the value above is 0.
mysql -e "SET GLOBAL gtid_mode = ON;"
~~~

Persist the completed state and verify it survives restart:

~~~bash
# Run on mysql1.
tee /etc/mysql/mysql.conf.d/99-sre-ha.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 10.255.1.1
server-id = 1
log_bin = mysql-bin
binlog_format = ROW
enforce_gtid_consistency = ON
gtid_mode = ON
EOF

chown root:root /etc/mysql/mysql.conf.d/99-sre-ha.cnf
chmod 0644 /etc/mysql/mysql.conf.d/99-sre-ha.cnf
runuser -u mysql -- test -r /etc/mysql/mysql.conf.d/99-sre-ha.cnf

systemctl restart mysql

mysql -e "SELECT @@server_id AS server_id, @@gtid_mode AS gtid_mode, @@enforce_gtid_consistency AS gtid_consistency, @@binlog_format AS binlog_format, @@log_bin AS binary_logging;"
~~~

Expected: server_id 1, gtid_mode ON, gtid_consistency ON, binlog_format ROW,
and binary_logging 1.

### 5.2 Install and stage mysql2

~~~bash
# Run on mysql2.
apt-get update
apt-get install -y mysql-server

tee /etc/mysql/mysql.conf.d/99-sre-ha.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 10.255.2.1
server-id = 2
log_bin = mysql-bin
relay_log = mysql-relay-bin
binlog_format = ROW
EOF

chown root:root /etc/mysql/mysql.conf.d/99-sre-ha.cnf
chmod 0644 /etc/mysql/mysql.conf.d/99-sre-ha.cnf
runuser -u mysql -- test -r /etc/mysql/mysql.conf.d/99-sre-ha.cnf

systemctl enable mysql
systemctl restart mysql
systemctl is-active mysql

mysql <<'SQL'
SET GLOBAL enforce_gtid_consistency = ON;
SET GLOBAL gtid_mode = OFF_PERMISSIVE;
SET GLOBAL gtid_mode = ON_PERMISSIVE;
SQL

mysql -e "SHOW STATUS LIKE 'ONGOING_ANONYMOUS_TRANSACTION_COUNT';"

# Continue only if the value above is 0.
mysql -e "SET GLOBAL gtid_mode = ON;"
~~~

~~~bash
# Run on mysql2.
tee /etc/mysql/mysql.conf.d/99-sre-ha.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 10.255.2.1
server-id = 2
log_bin = mysql-bin
relay_log = mysql-relay-bin
binlog_format = ROW
enforce_gtid_consistency = ON
gtid_mode = ON
EOF

chown root:root /etc/mysql/mysql.conf.d/99-sre-ha.cnf
chmod 0644 /etc/mysql/mysql.conf.d/99-sre-ha.cnf
runuser -u mysql -- test -r /etc/mysql/mysql.conf.d/99-sre-ha.cnf

systemctl restart mysql

mysql -e "SELECT @@server_id AS server_id, @@gtid_mode AS gtid_mode, @@enforce_gtid_consistency AS gtid_consistency, @@binlog_format AS binlog_format, @@log_bin AS binary_logging;"
~~~

Expected: server_id 2, gtid_mode ON, gtid_consistency ON, binlog_format ROW,
and binary_logging 1.

### 5.3 Create the replication account on mysql1

The source-password field used by CHANGE REPLICATION SOURCE TO accepts no more
than 32 characters in this environment. openssl rand -hex 16 creates exactly
32 safe characters. Record the value securely and transfer it only to the
mysql2 root session; never commit it.

~~~bash
# Run on mysql1.
REPL_PASSWORD="$(openssl rand -hex 16)"

mysql <<SQL
CREATE USER IF NOT EXISTS 'repl_user'@'10.255.2.1' IDENTIFIED BY '$REPL_PASSWORD';
ALTER USER 'repl_user'@'10.255.2.1' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'10.255.2.1';
SQL

printf 'Store this replication password securely: %s\n' "$REPL_PASSWORD"
~~~

### 5.4 Configure mysql2 as the GTID replica

Set REPL_PASSWORD in the mysql2 shell to the 32-character secret generated on
mysql1.

~~~bash
# Run on mysql2.
REPL_PASSWORD='<PASTE_REPLICATION_PASSWORD_HERE>'

mysql <<SQL
STOP REPLICA;

CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '10.255.1.1',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl_user',
  SOURCE_PASSWORD = '$REPL_PASSWORD',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_BIND = '10.255.2.1',
  GET_SOURCE_PUBLIC_KEY = 1;

START REPLICA;
SQL

unset REPL_PASSWORD
~~~

SOURCE_AUTO_POSITION makes MySQL use GTID coordinates rather than a binlog
file/position. SOURCE_BIND ensures replication starts from mysql2's stable
service address and therefore follows the OSPF-selected path.

### 5.5 Verify replication and real data

~~~bash
# Run on mysql2.
ip route get 10.255.1.1 from 10.255.2.1
ping -I 10.255.2.1 -c 3 10.255.1.1
nc -s 10.255.2.1 -zvw3 10.255.1.1 3306

mysql -e "SHOW REPLICA STATUS\G" | grep -E '^(Source_Host|Source_Bind|Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Errno|Last_IO_Error|Last_SQL_Errno|Last_SQL_Error):'
~~~

Healthy output includes:

~~~text
Source_Host: 10.255.1.1
Source_Bind: 10.255.2.1
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
~~~

Create test data on the primary only, then read it on the replica:

~~~bash
# Run on mysql1.
mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS mysql_ha;
CREATE TABLE IF NOT EXISTS mysql_ha.ha_test (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  note VARCHAR(255) NOT NULL,
  PRIMARY KEY (id)
);
INSERT INTO mysql_ha.ha_test (note) VALUES ('manual GTID replication test');
SQL

# Run on mysql2.
mysql -e 'SELECT * FROM mysql_ha.ha_test ORDER BY id DESC LIMIT 5;'
~~~

### 5.6 Confirm replication across the backup path

This proves the replication connection remains healthy when OSPF moves it from
WG-1 to WG-2.

~~~bash
# Run on mywireguard1.
systemctl stop frr

# Run on mysql2.
ip route get 10.255.1.1 from 10.255.2.1
mysql -e "SHOW REPLICA STATUS\G" | grep -E '^(Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error):'

# Run on mywireguard1 to restore normal service.
systemctl start frr
~~~

## 6. Final pre-monitoring checklist

~~~bash
# Run on every one of the four routing hosts.
wg show
systemctl is-active frr
vtysh -c 'show ip ospf neighbor'
vtysh -c 'show bfd peers'

# Run on mysql1.
ip route get 10.255.2.1 from 10.255.1.1
mysql -e "SELECT @@server_id, @@gtid_mode, @@enforce_gtid_consistency;"

# Run on mysql2.
ip route get 10.255.1.1 from 10.255.2.1
mysql -e "SHOW REPLICA STATUS\G" | grep -E '^(Source_Host|Source_Bind|Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source):'
~~~

Before moving to monitoring, confirm all four WireGuard handshakes are current,
all OSPF and BFD sessions are up, WG-1 is the normal route, WG-2 takes over
during a preferred-path failure, and both replication threads are running.
