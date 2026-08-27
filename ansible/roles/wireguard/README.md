# WireGuard role

**Implementation phase:** Phase 3 — implemented.

This role creates the four point-to-point WireGuard links that form the two
independent transit paths. Each interface gets its own private key, generated on
the target with `wg genkey`. Private keys never enter Git and are never returned
as Ansible command output.

## Route ownership

Every peer `AllowedIPs` contains the peer transit `/32`, exactly one stable service `/32` reachable/owned on that peer side, and the OSPFv2 multicast groups `224.0.0.5/32` and `224.0.0.6/32`; every interface has `Table = off`. The service selector is required for WireGuard outbound peer selection and inbound source validation. `Table = off` prevents `wg-quick` from installing those selectors as routes. FRR/OSPF (implemented in Phase 4)
decides the active end-to-end route.

## Local key handling

Files are stored under:

```text
/etc/wireguard/                 0700
/etc/wireguard/keys/            0700
/etc/wireguard/keys/*.private   0600
/etc/wireguard/keys/*.public    0644
/etc/wireguard/*.conf           0600
```

The generated `wg-quick` config does not contain the private key. Its `PostUp`
hook loads the host-local key with `wg set %i private-key ...`. Public keys are
derived on each target and shared as ephemeral Ansible host facts so peers can
be rendered correctly.

## Deployment prerequisite

Replace every `REPLACE_ME_*_PUBLIC_IP` and `REPLACE_ME_*_PRIVATE_IP` in
`inventory/hosts.yml`. Same-site links currently use private endpoints and
cross-site links use public endpoints; edit `peer_endpoint_address` in
`inventory/group_vars/wireguard.yml` if your cloud underlay differs.

Initial deployment or key rotation must include all members of the `wireguard`
inventory group so peer public keys can be exchanged in one Ansible run.

Run:

```bash
make network
```

After deployment, inspect a node with:

```bash
sudo wg show
sudo systemctl status wg-quick@wg1a
sudo ip address show dev wg1a
```
