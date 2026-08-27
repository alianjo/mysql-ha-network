# mysql_primary role

**Implementation:** active (Phase 5)

Install/configure the Tabriz MySQL GTID primary, binary logging, replication user, and HA-network binding.

The role is deployed by `ansible/mysql.yml` and configures the primary for GTID
replication on its stable service address.
