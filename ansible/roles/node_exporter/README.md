# node_exporter role

**Implementation:** active

Install node_exporter and configure the textfile collector used by custom SRE network/routing metrics.

The role installs a pinned node_exporter binary and a textfile collector for
WireGuard handshake and handshake-age, route, active path, OSPF, and BFD
health signals. The collector discovers the actual local WireGuard interface
names, including `wg1a`, `wg1b`, `wg2a`, and `wg2b`, and writes structured
network/path/failover/recovery events to the system journal on state changes.
