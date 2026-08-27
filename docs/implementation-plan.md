# Implementation Plan

## Architecture

The design has two independent routed transit paths between the MySQL hosts.
Neither WireGuard router depends on the other.

```text
                         WG-1 / preferred
                  +---- tabriz-wg01 ----+
                  |                     |
10.255.1.1/32     |                     |     10.255.2.1/32
tabriz-mysql01 ---+                     +--- shiraz-mysql01
                  |                     |
                  +---- shiraz-wg02 ----+
                         WG-2 / backup
```

The stable loopback addresses are the service identities for MySQL replication.
WireGuard transit addresses are never used as the replication source address.

## Interface Map

| Host | Interface | Address | UDP port | Peer | Path | Base OSPF cost |
|---|---|---:|---:|---|---|---:|
| tabriz-mysql01 | wg1a | 10.10.1.1/30 | 51811 | tabriz-wg01 | WG-1 | 10 |
| tabriz-wg01 | wg1a | 10.10.1.2/30 | 51811 | tabriz-mysql01 | WG-1 | 10 |
| tabriz-wg01 | wg1b | 10.10.1.5/30 | 51812 | shiraz-mysql01 | WG-1 | 10 |
| shiraz-mysql01 | wg1b | 10.10.1.6/30 | 51812 | tabriz-wg01 | WG-1 | 10 |
| tabriz-mysql01 | wg2a | 10.10.2.1/30 | 51821 | shiraz-wg02 | WG-2 | 100 |
| shiraz-wg02 | wg2a | 10.10.2.2/30 | 51821 | tabriz-mysql01 | WG-2 | 100 |
| shiraz-wg02 | wg2b | 10.10.2.5/30 | 51822 | shiraz-mysql01 | WG-2 | 100 |
| shiraz-mysql01 | wg2b | 10.10.2.6/30 | 51822 | shiraz-wg02 | WG-2 | 100 |

Linux interface names stay below the 15-character kernel limit. Each host has a
unique local WireGuard listen port per interface.

## IP Addressing

Stable MySQL service loopbacks:

- `tabriz-mysql01`: `10.255.1.1/32`
- `shiraz-mysql01`: `10.255.2.1/32`

Transit networks:

- WG-1 first leg: `10.10.1.0/30`
- WG-1 second leg: `10.10.1.4/30`
- WG-2 first leg: `10.10.2.0/30`
- WG-2 second leg: `10.10.2.4/30`

Public/private cloud addresses are intentionally not hard-coded. They are
provided per host in `inventory/hosts.yml`.

## WireGuard Route Ownership

`wg-quick` uses `Table = off`. Every peer `AllowedIPs` contains the peer transit `/32`, the one stable MySQL service `/32` that is reachable/owned on that peer side of the path, and the OSPFv2 multicast groups `224.0.0.5/32` and `224.0.0.6/32`. The service selector is required because WireGuard enforces AllowedIPs for outbound peer selection and inbound source validation. `Table = off` means none of these selectors are injected as kernel routes by `wg-quick`, so the stable routes `10.255.1.1/32` and `10.255.2.1/32` remain selected exclusively by FRR/OSPF.

This guarantees the two logical data paths remain independent:

```text
WG-1: tabriz-mysql01 -> tabriz-wg01 -> shiraz-mysql01
WG-2: tabriz-mysql01 -> shiraz-wg02 -> shiraz-mysql01
```

## OSPF Design

All four network nodes participate in OSPFv2 area `0.0.0.0`:

- `tabriz-mysql01`
- `tabriz-wg01`
- `shiraz-wg02`
- `shiraz-mysql01`

The MySQL hosts advertise only their stable loopback `/32` service addresses.
Loopbacks are passive in OSPF. Point-to-point WireGuard interfaces form OSPF
adjacencies.

WG-1 interfaces use cost `10`; WG-2 interfaces use cost `100`. The resulting
normal path cost makes WG-1 preferred while WG-2 remains installed as a valid
higher-cost backup. `routing_mode` defaults to `primary_backup`; ECMP is not
enabled.

## BFD Design

BFD is attached to OSPF on the WireGuard point-to-point adjacencies. Initial
cloud-safe defaults are:

- transmit interval: 500 ms
- receive interval: 500 ms
- multiplier: 3
- expected failure detection: approximately 1.5 seconds, subject to scheduling
  and network jitter

All values are inventory variables.

## End-to-End Failure Detection

BFD protects the control-plane adjacency, but it cannot prove useful data-plane
traffic. A small systemd-managed controller will run on both MySQL hosts.

Each controller probes the remote stable loopback through a specific first-hop
WireGuard interface. Because each transit router has only one onward leg toward
the remote MySQL host for that path, forcing the first hop selects the desired
forward path. Both MySQL hosts probe both directions so each path is validated
from both ends.

Default state machine:

1. probe every 1 second;
2. mark a path unhealthy after 3 consecutive failures;
3. raise the affected local OSPF interface cost to `1000`;
4. require 5 consecutive successful probes before considering recovery stable;
5. hold recovery for 30 seconds;
6. restore the configured base cost, allowing controlled automatic failback.

The controller only changes OSPF cost; it does not add static service routes.

## Failure Behavior

| Event | Primary detector | Routing action | Expected result |
|---|---|---|---|
| WG-1 process/link down | BFD + OSPF | adjacency withdrawn | WG-2 selected |
| WG-1 host down | BFD + OSPF | adjacency withdrawn | WG-2 selected |
| WG-1 data-plane blackhole | E2E controller | local WG-1 cost raised | WG-2 selected |
| Transient single probe loss | threshold logic | none | remain on WG-1 |
| WG-1 recovery | BFD/OSPF + E2E controller | hold-down then base cost restored | controlled failback to WG-1 |
| WG-2 failure while WG-1 healthy | monitoring/BFD | backup unavailable | remain on WG-1 and alert |

## Monitoring Design

`monitor-01` runs Prometheus, Grafana, Alertmanager, Blackbox Exporter, and
Loki. Nodes run node_exporter, with custom textfile collectors exposing
WireGuard, OSPF, BFD, route, path, and replication state where standard
exporters do not. The MySQL hosts also probe the remote stable MySQL service
address and expose ICMP/TCP availability, latency, and packet loss.

Grafana and Prometheus labels use the required site names: `tabriz`, `shiraz`,
and `observability`. The primary dashboard will be `MySQL HA Overview`.

## Logging Design

Grafana Alloy ships system, kernel/networking, FRR, WireGuard, MySQL,
health-controller, and failure-test logs to Loki on `monitor-01`. Labels include
`host`, `site`, `service`, and `component`. The collectors emit structured
events for network failure/recovery, path changes, failover/recovery, and
replication issues.

## Security Design

- WireGuard private keys are generated on target hosts and never stored in Git.
- `/etc/wireguard` will be mode `0700`; private keys will be mode `0600`.
- MySQL/Grafana secrets live in an encrypted Ansible Vault file.
- `inventory/group_vars/vault.yml` is Git-ignored.
- MySQL TCP/3306 is limited to the HA/internal routing domain.
- nftables rules will preserve SSH access and restrict exporter/management
  ports to `monitor-01` and the Ansible controller where practical.
- Monitoring UI exposure is intentionally controlled by cloud firewall rules
  and host firewall policy rather than assumed public access.
- Diagnostics will redact secrets and will never print WireGuard private keys.

## Cloud Firewall Inputs

The final host firewall and cloud-security-group rules depend on the real cloud
addresses. Required inputs are the public/private IPs of all five VMs and the
Ansible controller source IP/CIDR.

WireGuard UDP ports used by this design are 51811, 51812, 51821, and 51822, but
each host only needs the ports for interfaces it owns.

## Implementation Phases

1. Repository structure, inventory, variables, README skeleton, Makefile.
2. Common Linux configuration.
3. WireGuard topology and proof of independent paths.
4. FRR + OSPF + BFD and primary/backup route validation.
5. MySQL GTID primary/replica configuration.
6. Prometheus/Grafana/Alertmanager and exporters.
7. Loki + Alloy centralized logging.
8. Failure injection, recovery, and timing scripts.
9. pytest integration tests and unit-testable health-controller tests.
10. Runbooks, troubleshooting, RCA, interview demo, final README, and full
    consistency validation.

## Phase 1 Exit Criteria

Phase 1 is complete when:

- the Git repository exists;
- the five hosts and required groups are represented in inventory;
- cloud IPs are parameterized rather than hard-coded;
- stable loopbacks and all four point-to-point links are defined consistently;
- primary/backup OSPF costs and BFD/anti-flap defaults are variables;
- the Ansible Vault example contains no real secrets;
- `make help` and `make check` work locally.

## Phase 3 Implementation Record

Phase 3 implements the WireGuard layer described above. The implementation is
in `ansible/roles/wireguard` and is deployed by `ansible/wireguard.yml` (or the
current `ansible/network.yml`).

Key handling is intentionally host-local. Each WireGuard interface gets its own
private key under `/etc/wireguard/keys/<interface>.private` with mode `0600`.
Ansible executes `wg genkey` on the remote host with `creates:` semantics and
suppressed task logging. Only the derived public key is returned as a temporary
host fact so the reciprocal peer configuration can be rendered.

The generated interface configuration has `Table = off`, the peer transit `/32`, the required peer-side service `/32`, OSPF multicast `/32` `AllowedIPs`, and `PersistentKeepalive = 25`. The private key is not embedded in
the generated config; a `PostUp` hook loads it directly from the protected local
file. Therefore the repository and rendered Jinja template contain no private
key material.

Static topology proof is executable with:

```bash
make check
```

The validator requires exactly these graph edges and rejects a WG-1/WG-2 serial
chain:

```text
WG-1: tabriz-mysql01 -- tabriz-wg01 -- shiraz-mysql01
WG-2: tabriz-mysql01 -- shiraz-wg02 -- shiraz-mysql01
```

Live handshake/connectivity verification remains **NOT EXECUTED — requires live
infrastructure** until the real cloud endpoint addresses are supplied.


## Phase 4 Implementation Record

Phase 4 implements FRRouting, OSPFv2, and BFD in `ansible/roles/frr`. The
network playbook now applies `common -> wireguard -> frr` to exactly the four
routing nodes.

The MySQL service `/32`s are persisted on Linux `lo` by a systemd oneshot unit
ordered before FRR. FRR runs `zebra`, `ospfd`, and `bfdd`; OSPF is passive by
default and forms adjacencies only on the local WireGuard point-to-point
interfaces. The service loopback is advertised only by its owning MySQL host.

The static policy proof is executable with:

```bash
make check
```

It computes the graph directly from inventory and verifies:

```text
normal:   tabriz-mysql01 -> tabriz-wg01 -> shiraz-mysql01   cost 20
WG-1 out: tabriz-mysql01 -> shiraz-wg02 -> shiraz-mysql01   cost 200
```

BFD uses the `SRE_OSPF` profile with configurable 500 ms transmit, 500 ms
receive, and multiplier 3 defaults. The intended symmetric adjacent-link
failure detection target is approximately 1.5 seconds. OSPF hello/dead timers
remain 10/40 seconds so BFD, rather than fragile OSPF tuning, provides fast
failure detection.

Live OSPF adjacency, BFD state, and route convergence remain **NOT EXECUTED —
requires live infrastructure** until real cloud addresses are supplied.
