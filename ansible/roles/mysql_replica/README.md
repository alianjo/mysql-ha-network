# mysql_replica role

**Implementation:** active (Phase 5)

Install/configure the Shiraz MySQL GTID replica and source replication from stable address 10.255.1.1.

The role is deployed by `ansible/mysql.yml` and configures the replica to use
the primary's stable service address.
