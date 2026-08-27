# logging role

**Implementation:** active

Deploy Loki and Grafana Alloy, centralize system/network/FRR/WireGuard/MySQL/controller logs, and attach host/site/service/component labels.

The role installs Grafana Alloy as a systemd agent and forwards system logs,
MySQL and FRR log files when present, and the systemd journal to the central
Loki endpoint. Journal entries retain their systemd unit and syslog identifier
as `unit` and `service` labels. Monitoring collectors emit structured
`sre-ha-event` journal messages for network failure/recovery, path changes,
failover/recovery, and replication issues.

The journal source starts from the previous five minutes after a new agent
deployment. This prevents all hosts from flooding the single Loki instance with
historical entries at once; afterwards Alloy tails new entries continuously.
