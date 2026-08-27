# Loki

Loki runs as a single-node service on `monitor-01` with local filesystem-backed
TSDB storage. Grafana Alloy agents push labeled system, routing, WireGuard,
MySQL, and HA-event logs to its HTTP ingestion endpoint.
