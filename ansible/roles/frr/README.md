# FRR role

**Implementation phase:** Phase 4 — implemented.

This role installs FRRouting on all four network nodes and runs `zebra`,
`ospfd`, and `bfdd`. OSPFv2 area `0.0.0.0` runs only on the point-to-point
WireGuard interfaces; all other interfaces are passive by default.

## Route policy

The two MySQL service identities are persisted on Linux `lo` before FRR starts:

- `tabriz-mysql01`: `10.255.1.1/32`
- `shiraz-mysql01`: `10.255.2.1/32`

Only those two `/32`s are advertised as service prefixes. WG-1 interfaces have
OSPF cost `10` per hop and WG-2 interfaces have cost `100` per hop. Therefore
the normal end-to-end path has cost 20 via `tabriz-wg01`, while the backup has
cost 200 via `shiraz-wg02`.

No static route selects the active MySQL path and WireGuard remains `Table=off`.

## BFD

OSPF requests BFD on every WireGuard adjacency using profile `SRE_OSPF`.
Defaults are 500 ms transmit, 500 ms receive, multiplier 3. With symmetric
negotiation the intended detection time is approximately 1.5 seconds, subject
to host scheduling and network jitter. Values are configurable in
`inventory/group_vars/all.yml`.

The OSPF hello/dead timers remain deliberately conservative at 10/40 seconds;
BFD is the fast failure detector rather than aggressively tuning OSPF.

## Verification on a live node

```bash
sudo vtysh -c 'show ip ospf neighbor'
sudo vtysh -c 'show ip ospf interface'
sudo vtysh -c 'show bfd peers'
sudo vtysh -c 'show ip route 10.255.2.1'
ip route get 10.255.2.1
```

From `tabriz-mysql01`, the normal route to `10.255.2.1` must point toward WG-1.
After WG-1 is unavailable, OSPF must select WG-2. Phase 8 will automate timing
and failure injection; Phase 4 only implements and statically proves routing
policy.
