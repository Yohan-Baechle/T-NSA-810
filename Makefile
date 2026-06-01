.PHONY: help lint yamllint ansible-lint syntax-check deploy deploy-netbox deploy-elasticsearch deploy-bastion deploy-web deploy-filebeat deploy-metricbeat killswitch-cut killswitch-restore netbox-populate galaxy validate observability add-site-demo

.DEFAULT_GOAL := help

# --- Help ---
help: ## Affiche cette aide
	@echo "Commandes disponibles :"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		sort | \
		awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- Linting ---
lint: yamllint ansible-lint syntax-check ## Lance tous les linters (yaml, ansible, syntaxe)

yamllint: ## Vérifie le formatage YAML
	cd ansible && yamllint -c .yamllint .

ansible-lint: ## Analyse les playbooks avec ansible-lint
	cd ansible && ansible-lint -c .ansible-lint

syntax-check: ## Vérifie la syntaxe du playbook principal
	cd ansible && ansible-playbook playbooks/site.yml --syntax-check

# --- Galaxy dependencies ---
galaxy: ## Installe les dépendances Ansible Galaxy
	cd ansible && ansible-galaxy install -r requirements.yml

# --- Deployment ---
deploy: ## Déploie l'infra complète + met à jour l'IPAM (token + peuplement NetBox)
	cd ansible && ansible-playbook playbooks/site.yml --ask-vault-pass

deploy-netbox: ## Déploie uniquement NetBox
	cd ansible && ansible-playbook playbooks/netbox.yml --ask-vault-pass

deploy-elasticsearch: ## Déploie uniquement Elasticsearch
	cd ansible && ansible-playbook playbooks/elasticsearch.yml --ask-vault-pass

deploy-bastion: ## Déploie uniquement le bastion
	cd ansible && ansible-playbook playbooks/bastion.yml --ask-vault-pass

deploy-web: ## Déploie uniquement le serveur web
	cd ansible && ansible-playbook playbooks/web.yml --ask-vault-pass

deploy-filebeat: ## Déploie uniquement Filebeat
	cd ansible && ansible-playbook playbooks/filebeat.yml --ask-vault-pass

deploy-metricbeat: ## Déploie uniquement Metricbeat (métriques système)
	cd ansible && ansible-playbook playbooks/metricbeat.yml --ask-vault-pass

# --- Operations ---
killswitch-cut: ## Coupe d'urgence le VPN site-à-site (stoppe OpenVPN sur les 2 pfSense)
	cd ansible && ansible-playbook playbooks/killswitch.yml -e killswitch=cut --ask-vault-pass

killswitch-restore: ## Rétablit le VPN site-à-site (redémarre OpenVPN sur les 2 pfSense)
	cd ansible && ansible-playbook playbooks/killswitch.yml -e killswitch=restore --ask-vault-pass

netbox-populate: ## Génère le token NetBox et peuple l'IPAM
	cd ansible && ansible-playbook playbooks/netbox-token.yml --ask-vault-pass && \
		ansible-playbook playbooks/netbox-populate.yml --ask-vault-pass

# --- Validation & observabilité (read-only) ---
validate: ## Valide l'infra de bout en bout
	./scripts/validate.sh

observability: ## Analyse la télémétrie ES et génère docs/observability/report.html
	python3 scripts/observability.py

add-site-demo: ## Démontre l'ajout d'un 3e site (dry-run, sans déploiement)
	./scripts/add-site-demo.sh
