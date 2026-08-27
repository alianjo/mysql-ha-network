# Prometheus

The monitoring role provisions Prometheus on `monitor-01`. It scrapes the
node-exporter textfile metrics from all infrastructure hosts and runs independent
Blackbox ICMP probes against both MySQL hosts. Alert rules cover host, route,
WireGuard, OSPF/BFD, MySQL peer connectivity, latency/loss, and replication.
