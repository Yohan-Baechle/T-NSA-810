# CIA - Architecture de l'infrastructure

Infrastructure hybride multi-sites déployée sur **deux Proxmox distincts**,
interconnectés par un VPN site-to-site et automatisée en IaC (Ansible).

> **Schéma d'architecture** :
> [`diagrams/cia-infrastructure.isoflow.json`](diagrams/cia-infrastructure.isoflow.json)
> - vue d'ensemble (sites, LANs, VPN, pfSense, bastion, NetBox, Elasticsearch,
> DNS). Fichier source [Isoflow](https://isoflow.io) : l'ouvrir dans l'éditeur
> Isoflow pour le visualiser ou l'éditer.

## 1. Sites & hébergement

| Site | Rôle | Proxmox | Bloc agrégé |
| ---- | ---- | ------- | ----------- |
| **Site 1** (on-prem) | NetBox (IPAM), Elasticsearch (observabilité) | `ns3050272` (51.255.76.x) | `10.10.0.0/16` |
| **Site 2** (distant) | Bastion SSH, serveur web Nginx | `ns3183326` (146.59.253.x) | `10.20.0.0/16` |

Contraintes : **3 VMs max par site** (pfSense compris), 2 vCPU / 2 Go RAM /
10 Go disque par VM, droits Proxmox limités (VM pré-créées, un seul bridge LAN
par site). La séparation des flux se fait donc **sur pfSense** (règles entre IP),
pas en multipliant les VMs ni les interfaces.

## 2. Plan d'adressage - agrégé /16 par site, zoné en /24

Principe directeur : un bloc `10.<site>0.0.0/16` réservé par site, avec un LAN
`/24` actif par site. Schéma résumable (une seule route `/16` par site dans le
VPN) et scalable (site N = `10.<N0>.0.0/16`, il suffit d'incrémenter). Source de
vérité unique :
[`ansible/inventory/group_vars/all/vars.yml`](../ansible/inventory/group_vars/all/vars.yml).

| Site | LAN | Passerelle (pfSense) | Hôtes |
| ---- | --- | -------------------- | ----- |
| **S1** | `10.10.0.0/24` | `10.10.0.1` | netbox-s1 `.10`, elastic-s1 `.20` |
| **S2** | `10.20.0.0/24` | `10.20.0.1` | bastion-s2 `.10`, web-s2 `.20` |

### Séparation des zones - logique, pas physique

Les nodes Proxmox n'exposent qu'**un seul bridge LAN par site** (`vmbr132`) et la
configuration réseau des nodes n'est pas accessible (pas de création de bridge
ni de VLAN). La séparation Admin / Services / DMZ est donc **logique** : elle se
fait par règles pfSense entre IP, sur l'unique LAN, plutôt que par interfaces
séparées. Le `/16` reste réservé par site pour basculer en VLAN si un accès à la
configuration réseau des nodes devient disponible (voir `docs/SCALING.md`).

Zones logiques (étiquettes `host_zone` dans l'inventaire) :

| Zone logique | Hôtes | Politique de flux |
| ------------ | ----- | ----------------- |
| admin | bastion-s2 `10.20.0.10` | seule entrée externe ; SSH vers les autres hôtes |
| services | netbox-s1 `10.10.0.10`, elastic-s1 `10.10.0.20` | accès interne ; reçoit les logs Filebeat |
| dmz | web-s2 `10.20.0.20` | reçoit du HTTP interne ; n'initie aucun flux sortant interne |

### Tunnel VPN OpenVPN (site-to-site)

| Élément | Valeur |
| ------- | ------ |
| Type | Peer to Peer |
| Protocole | UDP4, port 1194 |
| Chiffrement | AES-256-GCM, SHA256 |
| Terminaisons | WAN public S1 <-> WAN public S2 |
| CA | CIA-CA (créée sur pfSense S1, importée sur S2) |
| Rôles | S1 = serveur, S2 = client |
| Tunnel network | `10.0.0.0/30` (S1 = `10.0.0.1`, S2 = `10.0.0.2`) |
| Routes annoncées S1 -> S2 | `10.20.0.0/16` |
| Routes annoncées S2 -> S1 | `10.10.0.0/16` |

Les blocs `10.10.0.0/16`, `10.20.0.0/16` et le tunnel `10.0.0.0/30` ne se
chevauchent pas.

## 3. Pare-feux pfSense & séparation des flux

Une VM pfSense par site (2 vCPU / 2 Go RAM / 32 Go disque), avec WAN + LAN. La
séparation des flux se fait par règles entre IP sur le LAN (zones logiques).
Règles clés (moindre privilège) :

- **Bastion** (`10.20.0.10`) : seule porte d'entrée externe. WAN autorise **SSH
  uniquement** vers le bastion ; le bastion accède aux autres hôtes des 2 sites
  via le VPN, en **SSH only**.
- **Web** (`10.20.0.20`) : joignable **uniquement depuis l'interne** (LAN des 2
  sites via VPN) ; aucune règle WAN -> web. Le web n'initie aucun flux sortant
  vers les autres hôtes internes.
- **NetBox / Elasticsearch** (`10.10.0.10` / `10.10.0.20`) : accessibles depuis
  l'interne des 2 sites ; Filebeat des VM -> Elasticsearch `:9200/5044` autorisé ;
  le reste bloqué.
- **NAT outbound** : Automatic sur S1 et S2 ; les VM accèdent à internet via
  pfSense (pas de connexion directe WAN).

### Kill switch

Coupure d'urgence du VPN inter-sites sans modifier la configuration (recovery
instantanée) : [`ansible/playbooks/killswitch.yml`](../ansible/playbooks/killswitch.yml)
(`make killswitch-cut` / `make killswitch-restore`).

## 4. DNS

- Chaque VM résout via l'interface Admin du pfSense de son site (`site_dns`).
- Search domains : `site1.lan` et `site2.lan` (domaines internes en `.lan` ;
  `.local` est évité car réservé au mDNS et non forwardable proprement).
- **DNS forwarding inter-sites** : pfSense S1 résout `site1.lan` et forwarde
  `site2.lan` -> pfSense S2 (et inversement), via le tunnel VPN.

## 5. VMs applicatives

Toutes : **Ubuntu Server 24.04 LTS minimal**, 2 vCPU / 2 Go RAM / 10 Go disque,
une seule interface réseau (LAN du site).

| Hostname | IP | Zone logique | Site | Rôle |
| -------- | -- | ------------ | ---- | ---- |
| netbox-s1 | `10.10.0.10` | services | S1 | NetBox (IPAM) |
| elastic-s1 | `10.10.0.20` | services | S1 | Elasticsearch |
| bastion-s2 | `10.20.0.10` | admin | S2 | Bastion SSH |
| web-s2 | `10.20.0.20` | dmz | S2 | Serveur web Nginx |

### Contraintes RAM critiques

- **Elasticsearch** : heap JVM limité à 512 Mo (`-Xms512m -Xmx512m`) - sinon OOM.
- **NetBox** : PostgreSQL + Redis + NetBox sur 2 Go RAM - tuning nécessaire.

### Configuration réseau (netplan - `50-cloud-init.yaml.j2`)

- IP/préfixe/gateway dérivés des `host_vars`.
- Gateway = interface LAN du pfSense du site (`10.X0.0.1`).
- IPv6 désactivé ; apt forcé en IPv4.

## 6. Accès & élévation de privilèges

- Accès aux VM internes **via le bastion S2** (ProxyJump, cf.
  [`ansible/ansible.cfg`](../ansible/ansible.cfg)). Aucun accès direct aux
  réseaux privés `10.x` depuis l'extérieur.
- Clé SSH ed25519, authentification par clé uniquement (password auth désactivé,
  root login interdit - cf. rôle `common`).
- `become: sudo`, mot de passe sudo fourni via **Ansible Vault**
  (`vault_become_password`).

## 7. Scalabilité - ajout d'un site

Le motif `10.<N0>.0.0/16` permet d'onboarder un 3ᵉ site (`10.30.0.0/16`) avec le
même gabarit. Procédure détaillée : voir `docs/SCALING.md`.

## 8. Stack technique

| Composant | Choix | Rôle |
| --------- | ----- | ---- |
| Virtualisation | Proxmox VE | Hôtes des VM |
| Firewall / Routeur | pfSense | Filtrage, NAT, VPN, DNS resolver |
| VPN | OpenVPN (site-to-site) | Interconnexion chiffrée S1 <-> S2 |
| IPAM | NetBox | Source de vérité réseau (IP, prefixes, devices) |
| Observabilité | Elasticsearch + Filebeat | Centralisation des logs |
| Automatisation | Ansible | IaC (rôles, playbooks, inventaire) |

Versions et collections : voir [`ansible/requirements.yml`](../ansible/requirements.yml)
et [`requirements.txt`](../requirements.txt). Toutes les briques sont activement
maintenues par leur communauté.
