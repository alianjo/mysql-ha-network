# mysql_exporter role

**Implementation:** active

Install least-privilege MySQL textfile collectors with Vault-backed credentials.

The role installs a least-privilege MySQL account and a systemd textfile
collector for replication thread state and lag. A second collector runs on
each MySQL host and probes the other host's stable service address with ICMP
and TCP/3306. It exposes availability, latency, packet loss, active path, and
structured failure/recovery/failover events.
