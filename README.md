# CIA - Cloud Infrastructure Architects

Projet Epitech : déploiement et sécurisation d'une infrastructure hybride multi-sites avec Proxmox, pfSense et Ansible.

## Architecture

- **Site 1** (LAN 10.10.0.0/24, on-prem) : NetBox (IPAM), Elasticsearch (observabilité)
- **Site 2** (LAN 10.20.0.0/24, distant) : Bastion SSH, serveur web Nginx
- **Inter-sites** : VPN OpenVPN site-to-site via pfSense (tunnel 10.0.0.0/30)
- **Firewall** : pfSense sur chaque site (séparation des flux par règles entre IP)
- **Observabilité** : Filebeat sur toutes les VMs -> Elasticsearch

Plan d'adressage détaillé : voir [docs/infra.md](docs/infra.md).

## Prérequis

- 2 sites Proxmox distincts
- 2 VMs pfSense (firewall/VPN) + 4 VMs Ubuntu Server 24.04 minimal
- Python >= 3.12
- Git
- Accès SSH (clé publique copiée sur toutes les VMs)

## Installation

```bash
# 1. Cloner le repo
git clone git@github.com:EpitechMscProPromo2027/T-NSA-810-NCY_10.git
cd T-NSA-810-NCY_10

# 2. Créer un environnement virtuel Python
python3 -m venv .venv
source .venv/bin/activate

# 3. Installer les dépendances Python
pip install -r requirements.txt

# 4. Installer les collections Ansible Galaxy
make galaxy

# 5. (Optionnel) Activer les hooks pre-commit
pre-commit install
```

## Configuration

Avant le premier déploiement, adaptez les fichiers suivants à votre infrastructure :

### 1. Inventaire - `ansible/inventory/hosts.yml`

Modifier les `ansible_host` et `ansible_user` selon vos VMs :

```yaml
all:
  children:
    site1:
      hosts:
        netbox-s1:
          ansible_host: 10.10.0.10    # S1 LAN
          ansible_user: netbox          # User SSH avec droits sudo
        elastic-s1:
          ansible_host: 10.10.0.20    # S1 LAN
          ansible_user: elastic
    site2:
      hosts:
        bastion-s2:
          ansible_host: 5.135.202.79   # IP publique du bastion (accès SSH direct)
          ansible_port: 2222           # port-forward WAN -> :22
          ansible_user: bastion
        web-s2:
          ansible_host: 10.20.0.20    # S2 LAN (web interne)
          ansible_user: web
```

Le **bastion** est la seule VM jointe en direct (IP publique). Les autres VM ne
sont pas exposées : elles sont atteintes en rebond via le bastion.

### 2. Connexion SSH - rebond via le bastion

Le rebond (ProxyJump) est défini dans `ansible/inventory/group_vars/all/vars.yml`
(`ansible_ssh_common_args`), pas dans `ansible.cfg`. Il s'appuie sur un alias
`cia-bastion` que vous déclarez dans votre `~/.ssh/config` :

```sshconfig
Host cia-bastion
    HostName <ip_publique_bastion>
    Port 2222
    User bastion
    IdentityFile ~/.ssh/cia_ansible
```

Le bastion s'auto-exclut du rebond via son `host_vars` (sinon il rebondirait
sur lui-même).

### 3. Vault - secrets chiffrés

Les secrets (mots de passe sudo, tokens API) sont dans `ansible/inventory/group_vars/all/vault.yml`, chiffré avec `ansible-vault`.

```bash
# Créer votre propre vault à partir du template
cp ansible/inventory/group_vars/all/vault.yml.example ansible/inventory/group_vars/all/vault.yml
ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml
```

Pour éditer les secrets :

```bash
ansible-vault edit ansible/inventory/group_vars/all/vault.yml
```

Le mot de passe du vault est demandé à chaque commande (`--ask-vault-pass`).
Aucun secret n'est versionné : `vault.yml` est chiffré et le fichier de mot de
passe éventuel reste local (exclu via `.gitignore`).

### 4. Variables - `ansible/inventory/group_vars/`

Les valeurs par défaut de chaque rôle sont dans son fichier `defaults/main.yml`.

## Déploiement

```bash
# Infrastructure complète (tous les rôles dans l'ordre)
make deploy

# Service individuel
make deploy-netbox
make deploy-elasticsearch
make deploy-bastion
make deploy-web
make deploy-filebeat
```

## Opérations

```bash
# Emergency kill switch (coupe le VPN inter-sites)
make killswitch-cut

# Restauration du VPN
make killswitch-restore

# Re-jouer la mise à jour de l'IPAM seule (sans redéployer l'infra)
make netbox-populate
```

## Mise à jour de l'IPAM (NetBox)

L'IPAM est tenu **à jour automatiquement** : `make deploy` déploie l'infra puis
rejoue, dans le même geste, la création du token API et le peuplement NetBox
(sites, préfixes, devices, adresses). Les données proviennent des variables
Ansible (source de vérité) et les modules sont idempotents - rejouer ne crée pas
de doublon et corrige toute dérive.

`make netbox-populate` permet de rejouer l'IPAM seul (correction de données sans
redéploiement complet).

Justification du choix (source de vérité Ansible, alternatives écartées,
évolution possible) : voir [docs/adr/0001-ipam-automation.md](docs/adr/0001-ipam-automation.md).

## Linting & CI

```bash
# Lancer tous les linters localement
make lint

# Individuellement
make yamllint
make ansible-lint
make syntax-check
```

Le pipeline GitHub Actions (`.github/workflows/lint.yml`) exécute automatiquement `yamllint`, `ansible-lint` et `syntax-check` sur chaque push/PR sur `main`.

## Structure du projet

```
cia-project/
├── requirements.txt              # Dépendances Python
├── Makefile                      # Commandes make
├── .pre-commit-config.yaml       # Hooks pre-commit
├── .editorconfig                 # Conventions éditeur
├── .github/
│   ├── CODEOWNERS                # Review obligatoire
│   └── workflows/lint.yml        # CI GitHub Actions
├── docs/
│   ├── infra.md                  # Architecture détaillée (adressage, VPN, firewall, DNS)
│   ├── diagrams/                 # Schéma d'architecture (source Isoflow)
│   ├── pfsense-setup.md          # Configuration pfSense + VPN/firewall/DNS/syslog (pas à pas)
│   ├── SCALING.md                # Procédure d'ajout d'un nouveau site
│   ├── runbook.md                # Exploitation + plan de reprise (DRP)
│   ├── observability/            # Analyse de la télémétrie (rapport + graphes)
│   ├── planning/                 # Gantt + backlog (projet)
│   └── adr/                      # Décisions d'architecture (ADR)
└── ansible/
    ├── ansible.cfg               # Configuration Ansible
    ├── .ansible-lint              # Profil production
    ├── .yamllint                  # Règles yamllint
    ├── requirements.yml           # Collections Galaxy
    ├── inventory/
    │   ├── hosts.yml             # Inventaire des VMs
    │   ├── group_vars/           # Variables par groupe
    │   └── host_vars/            # Variables par host
    ├── playbooks/
    │   ├── site.yml              # Playbook master
    │   ├── killswitch.yml        # Emergency cut-off VPN
    │   ├── netbox-populate.yml   # Population IPAM
    │   ├── netbox-token.yml      # Création token API NetBox
    │   ├── filebeat.yml          # Déploiement Filebeat
    │   └── *.yml                 # Playbooks par service
    └── roles/
        ├── common/               # Hardening SSH, netplan, paquets de base
        ├── netbox/               # IPAM (PostgreSQL + Redis + Nginx)
        ├── elasticsearch/        # Centralisation des logs
        ├── filebeat/             # Envoi des logs vers Elasticsearch
        ├── bastion/              # Bastion SSH (fail2ban + auditd)
        └── web/                  # Serveur web Nginx (headers sécurité)
```

## Documentation

- [docs/infra.md](docs/infra.md) - Architecture détaillée, plan d'adressage, VPN, firewall, DNS
- [docs/diagrams/](docs/diagrams/) - Schéma d'architecture (source Isoflow, à ouvrir sur isoflow.io)
- [docs/pfsense-setup.md](docs/pfsense-setup.md) - Configuration pfSense : VPN, firewall, DNS, syslog (pas à pas)
- [docs/SCALING.md](docs/SCALING.md) - Procédure d'ajout d'un nouveau site (scalabilité)
- [docs/runbook.md](docs/runbook.md) - Exploitation, reconstruction et plan de reprise (DRP)
- [docs/observability/](docs/observability/) - Analyse de la télémétrie (logs + métriques + firewall)
- [docs/planning/](docs/planning/) - Gantt et backlog du projet
- [docs/adr/](docs/adr/) - Décisions d'architecture (ADR), avec justification des choix techniques
