# common role

Phase 2 operating-system baseline for all five hosts.

It validates Ubuntu, sets the hostname/timezone, installs shared packages,
creates common state/log/config directories, writes safe `/etc/hosts` entries
only when real private IPs are supplied, applies networking sysctls, enables
IPv4 forwarding only on the two transit routers, and creates a non-restrictive
nftables include foundation.

The nftables role foundation intentionally does **not** install a default-drop
policy yet. Service-specific firewall rules are added with the corresponding
network/monitoring roles once their ports and trusted source CIDRs are known;
this avoids locking out the Ansible SSH session during the baseline phase.
