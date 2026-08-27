# Grafana Alloy

Alloy runs as a systemd agent on every infrastructure host. It reads service
log files and the systemd journal, preserving `host`, `site`, `component`,
`unit`, and `service` labels before forwarding entries to Loki.
