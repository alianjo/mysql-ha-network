# Network Design — Phase 3 WireGuard

## Purpose

Phase 3 created four encrypted point-to-point links and no end-to-end static
service routes. Phase 4 now layers FRR/OSPF/BFD over those links; see
[`routing.md`](routing.md).

## Independent paths

```text
WG-1 / preferred routing path (OSPF cost 10 per hop)

tabriz-mysql01 wg1a 10.10.1.1/30
        |
        | UDP 51811 / WireGuard
        |
tabriz-wg01    wg1a 10.10.1.2/30
        |
        | wg1b / UDP 51812 / WireGuard
        |
shiraz-mysql01 wg1b 10.10.1.6/30

WG-2 / backup routing path

tabriz-mysql01 wg2a 10.10.2.1/30
        |
        | UDP 51821 / WireGuard
        |
shiraz-wg02    wg2a 10.10.2.2/30
        |
        | wg2b / UDP 51822 / WireGuard
        |
shiraz-mysql01 wg2b 10.10.2.6/30
```

`tabriz-wg01` and `shiraz-wg02` never peer with each other. A failure of either
transit router therefore cannot make the other path depend on the failed router.

## AllowedIPs and route ownership

Each peer admits exactly:

- the peer transit address as a `/32`;
- the single stable MySQL service `/32` reachable/owned on that peer side of the path;
- `224.0.0.5/32` (OSPF AllSPFRouters multicast);
- `224.0.0.6/32` (OSPF AllDRouters multicast).

WireGuard uses `AllowedIPs` for outbound peer selection and inbound source validation, not only for optional route installation. The service `/32` is therefore required for actual routed MySQL traffic to cross each tunnel. The OSPF multicast entries are required for OSPFv2 control traffic. Every interface sets `Table = off`, so `wg-quick` installs none of these selectors as kernel routes; FRR/OSPF remains the only mechanism choosing the active service path.

## Underlay endpoints

Same-site links default to the peer `private_ip`; cross-site links default to the
peer `public_ip`. This is only an inventory policy and can be changed per link
with `peer_endpoint_address` if the cloud provides routed private connectivity
between sites, NAT gateways, or another underlay design.

Before running `make network`, replace all `REPLACE_ME_*` public/private
addresses in `inventory/hosts.yml`.

## Cloud firewall/security-group prerequisite

Allow each WireGuard UDP listener **only from its configured peer underlay
address**, not from the Internet at large:

| Destination | UDP port | Required peer |
|---|---:|---|
| `tabriz-mysql01` | 51811 | `tabriz-wg01` |
| `tabriz-mysql01` | 51821 | `shiraz-wg02` |
| `tabriz-wg01` | 51811 | `tabriz-mysql01` |
| `tabriz-wg01` | 51812 | `shiraz-mysql01` |
| `shiraz-wg02` | 51821 | `tabriz-mysql01` |
| `shiraz-wg02` | 51822 | `shiraz-mysql01` |
| `shiraz-mysql01` | 51812 | `tabriz-wg01` |
| `shiraz-mysql01` | 51822 | `shiraz-wg02` |

The host nftables policy is intentionally still non-restrictive in Phase 3 so a
partial firewall implementation cannot lock out Ansible. Restrictive host
firewall rules are added as part of the security-complete network phase; cloud
security groups should provide the Phase 3 underlay restriction above.

## Key lifecycle

Each local interface has an independent private key generated on the target:

```text
/etc/wireguard/keys/wg1a.private
/etc/wireguard/keys/wg1b.private
/etc/wireguard/keys/wg2a.private
/etc/wireguard/keys/wg2b.private
```

Only files corresponding to interfaces present on a host are created. Private
keys are mode `0600`; `/etc/wireguard` and its `keys` directory are mode `0700`.
The peer public key is derived with `wg pubkey` during each Ansible run.

To rotate a single interface key, stop the affected interface, remove only its
`.private` key on that host, and run the WireGuard play against the full
`wireguard` group. Ansible derives the new public key, updates the reciprocal
peer config, and restarts only interfaces whose key or config changed.

## Static proof

Run:

```bash
make check
```

This validates the reciprocal graph, `/30` pairing, UDP endpoint/listener
symmetry, AllowedIPs, cost metadata, and the absence of a WG-1/WG-2 serial edge.
It is a configuration proof only; live handshakes require the actual VMs.
