# Monitoring and logging

1. Copy `inventory/group_vars/vault.yml.example` to `inventory/group_vars/vault.yml`, set real values, and encrypt it.
2. Replace all `REPLACE_ME_*` inventory values.
3. Allow monitor ports 9090, 9093, 3000, and 3100, and allow agents to reach Loki on 3100.
4. Run `make check`, then `make monitoring`.

The playbook installs pinned node-exporter and Alloy systemd agents, and starts
the Docker Compose stack on `monitor-01`.

Prometheus collects metrics every 15 seconds. The custom network collector
records WireGuard peer state and handshake age, stable-route presence, active
OSPF-selected interface, OSPF full neighbors, and BFD sessions. Use
`sre_active_path{interface=~"wg2.*"}` to identify backup-path operation.

Each MySQL host also probes the other host's stable MySQL service address. The
following metrics prove end-to-end connectivity across the selected HA path:

- `sre_mysql_peer_icmp_up` and `sre_mysql_peer_tcp_up` — ICMP and TCP/3306 availability;
- `sre_mysql_peer_latency_seconds` — average ICMP round-trip latency;
- `sre_mysql_peer_packet_loss_percent` — loss across the probe packet set.

The provisioned **MySQL HA Overview** dashboard graphs selected path, route
availability, WireGuard status and handshake age, OSPF/BFD, MySQL-to-MySQL
connectivity, latency, packet loss, and replication thread state and lag.
It also includes an HA event-log panel.

Check Prometheus `/targets` and `/alerts`, Grafana on port 3000, and Loki in
Grafana Explore. On a monitored host inspect:

```bash
systemctl status node-exporter alloy
cat /var/lib/node_exporter/textfile_collector/sre_network.prom
cat /var/lib/node_exporter/textfile_collector/mysql_replication.prom
cat /var/lib/node_exporter/textfile_collector/mysql_connectivity.prom
```

For testing, stop `node-exporter` or break a WireGuard peer and wait for the
alert `for:` interval; restore it and confirm resolution. Use
`logger -t sre-ha-event 'event=TEST host=HOSTNAME'` and query
`{service="sre-ha-event"}` in Loki to verify centralized event logs. The
collectors emit `NETWORK_FAILURE`, `NETWORK_RECOVERY`, `PATH_CHANGE`,
`FAILOVER`, `RECOVERY`, `REPLICATION_ISSUE`, and replication-lag events only
when the observed state changes, avoiding repeated log noise.
