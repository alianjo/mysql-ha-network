# Dynamic Routing: FRR, OSPFv2, and BFD

## Scope

Phase 4 installs FRRouting on `tabriz-mysql01`, `tabriz-wg01`, `shiraz-wg02`,
and `shiraz-mysql01`. WireGuard supplies encrypted point-to-point links; OSPF
owns end-to-end reachability for the stable MySQL service addresses.

No static route selects WG-1 or WG-2.

## Stable service routes

`tabriz-mysql01` owns `10.255.1.1/32` on Linux `lo` and advertises it into OSPF.
`shiraz-mysql01` owns `10.255.2.1/32` and advertises that `/32`.

A systemd oneshot unit named `sre-mysql-loopback.service` persists each address
and is ordered before `frr.service`. The transit routers do not receive service
loopbacks.

## OSPF topology and costs

All routing interfaces are point-to-point and belong to area `0.0.0.0`.

```text
                         cost 10             cost 10
10.255.1.1/32   tabriz-mysql01 -- tabriz-wg01 -- shiraz-mysql01   10.255.2.1/32
                        \                              /
                         \ cost 100          cost 100 /
                          +------ shiraz-wg02 --------+
```

Normal route cost is therefore:

```text
WG-1 = 10 + 10  = 20
WG-2 = 100 + 100 = 200
```

FRR uses `passive-interface default` and explicitly un-passives only the local
WireGuard interfaces. This prevents OSPF from accidentally forming adjacencies
on cloud public/private interfaces.

Router IDs are fixed protocol identifiers in `inventory/group_vars/routing.yml`
and do not depend on cloud addressing.

## BFD

`bfdd` is enabled and OSPF requests a BFD session on every WireGuard adjacency
using profile `SRE_OSPF`.

Default values:

| Setting | Value |
|---|---:|
| Transmit interval | 500 ms |
| Receive interval | 500 ms |
| Detect multiplier | 3 |
| Symmetric target detection | ~1.5 s |

The exact negotiated failure time depends on both peers, host scheduling, and
network jitter. With both ends using the project defaults, approximately 1.5
seconds is the intended target. These values are deliberately less aggressive
than sub-300-ms cloud timers.

OSPF keeps 10-second hello and 40-second dead timers. BFD is the fast detector;
OSPF timers are not reduced to unstable values merely to make demonstrations
look faster.

## Failure behavior

When a WG-1 BFD session fails, OSPF removes the corresponding adjacency and the
cost-200 WG-2 route becomes the best remaining path. When WG-1 returns, native
OSPF again prefers cost 20. Phase 8 adds the end-to-end health controller and
hold-down behavior required to prevent unsafe immediate failback after a
higher-layer/data-plane failure.

BFD detects forwarding failure between adjacent OSPF peers. It does **not** prove
that useful end-to-end traffic traverses both WireGuard legs; that distinction
is why the later end-to-end controller remains required.

## Static validation

Run:

```bash
make check
```

The validator constructs the graph from inventory and proves:

- the routing group contains exactly the four required nodes;
- WG-1 is the unique lowest-cost normal route;
- removing `tabriz-wg01` leaves the WG-2 path intact;
- removing `shiraz-wg02` leaves WG-1 intact;
- only the two MySQL hosts advertise stable service `/32`s;
- rendered FRR configuration has no static MySQL route;
- OSPF is passive by default and BFD is attached to every WG adjacency.

## Live verification

After `make network`, run on `tabriz-mysql01`:

```bash
sudo vtysh -c 'show ip ospf neighbor'
sudo vtysh -c 'show bfd peers'
sudo vtysh -c 'show ip route 10.255.2.1'
ip route get 10.255.2.1
```

Expected healthy topology from each MySQL server is two OSPF neighbors: one via
WG-1 and one via WG-2. The best OSPF route to the remote stable loopback must use
WG-1 during normal operation.

Useful router-side checks:

```bash
sudo vtysh -c 'show ip ospf interface'
sudo vtysh -c 'show bfd peers'
sudo vtysh -c 'show ip route ospf'
sudo journalctl -u frr --since '-10 min'
```

Live adjacency and convergence results are **NOT EXECUTED — requires live
infrastructure** until real inventory endpoints are supplied.
