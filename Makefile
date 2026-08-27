SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

INVENTORY := inventory/hosts.yml
ANSIBLE_PLAYBOOK := ansible-playbook

.PHONY: help install-deps common network mysql monitoring site check test

help: ## Show the important commands
	@printf '%s\n' \
	  'MySQL HA Network commands:' \
	  '  make install-deps  Install Ansible collections' \
	  '  make common        Configure the common server baseline' \
	  '  make network       Deploy WireGuard and FRR routing' \
	  '  make mysql         Configure MySQL replication' \
	  '  make monitoring    Deploy metrics, dashboards, and logs' \
	  '  make site          Deploy the complete stack in dependency order' \
	  '  make check         Validate the network design' \
	  '  make test          Run the test suite'

install-deps: ## Install required Ansible Galaxy collections
	ansible-galaxy collection install -r requirements.yml

common: ## Configure the common baseline on all hosts
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/common.yml

network: ## Deploy WireGuard and FRR/OSPF/BFD routing
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/network.yml

mysql: ## Deploy MySQL GTID replication
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/mysql.yml

monitoring: ## Deploy metrics, alerts, dashboards, and logs
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/monitoring.yml

site: ## Deploy the complete stack in dependency order
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/site.yml

check: ## Validate the WireGuard and routing designs
	python3 scripts/validate_wireguard_topology.py
	python3 scripts/validate_routing_design.py

test: ## Run the test suite
	python3 -m pytest -q
