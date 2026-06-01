# CIA - Disaster Recovery Plan & Runbook

## 1. Scénarios de sinistre

| Scénario | Impact | Criticité |
| --- | --- | --- |
| Perte d'une VM applicative | Service indisponible | Haute |
| Perte du VPN inter-sites | Sites isolés, pas de communication S1<->S2 | Haute |
| Perte d'un pfSense | Site sans internet + sans firewall | Critique |
| Perte du serveur Proxmox | Perte totale de l'infrastructure | Critique |
| Compromission du bastion | Accès non autorisé au réseau interne | Critique |
| Disque plein sur une VM | Service en panne (Elasticsearch, NetBox) | Moyenne |

## 2. Procédures de recovery

### 2.1 Perte d'une VM applicative

**Temps estimé : 15-30 min**

1. Recréer la VM sur Proxmox avec les mêmes specs (2 vCPU, 2GB RAM, 10GB disque)
2. Installer Ubuntu Server 24.04 minimal
3. Copier la clé SSH : `ssh-copy-id -i ~/.ssh/id_ed25519 <user>@<ip>`
4. Redéployer le service :

```bash
# NetBox
make deploy-netbox

# Elasticsearch
make deploy-elasticsearch

# Bastion
make deploy-bastion

# Web
make deploy-web
```

5. Redéployer Filebeat : `make deploy-filebeat`
6. Si la VM NetBox a été reconstruite : repeupler l'IPAM avec `make netbox-populate`
   (le redéploiement par service ne le fait pas - seul `make deploy` enchaîne l'IPAM)

### 2.2 Perte du VPN inter-sites

**Temps estimé : 5-10 min**

1. Vérifier l'état du VPN sur pfSense S1 : Status > OpenVPN
2. Si le service est arrêté, restaurer via Ansible :

```bash
make killswitch-restore
```

3. Si la config est corrompue :
   - Reconfigurer OpenVPN sur pfSense S1 (serveur) et S2 (client)
   - Paramètres : UDP4, port 1194, AES-256-GCM, tunnel `10.0.0.0/30`
   - Remote networks annoncés : `10.20.0.0/16` (côté S1) et `10.10.0.0/16` (côté S2)

4. Vérifier la connectivité :

```bash
# depuis netbox-s1 (S1/Services) vers le bastion (S2/Admin) via le VPN
ssh netbox-s1 'ping -c2 10.20.0.10'
```

### 2.3 Perte d'un pfSense

**Temps estimé : 30-60 min**

1. Recréer la VM pfSense sur Proxmox (2 vCPU, 2GB RAM, 32GB disque)
2. Installer pfSense 2.7.2
3. Configurer les interfaces :
   - **WAN** (vtnet0) : IP publique du site
   - **LAN** (vtnet1, bridge `vmbr132`) : `10.<site>0.0.1/24`
     (S1 = 10.10.0.1, S2 = 10.20.0.1)
4. NAT outbound : mode **Automatic** (NAT le LAN vers le WAN).
   ⚠️ ne jamais lancer `pfctl -d` : ça désactive `pf` et donc le NAT.
5. Configurer le DNS Resolver (Services > DNS Resolver) + forwarding de l'autre site via le VPN
6. Reconfigurer OpenVPN (voir §2.2)
7. Recréer les règles firewall (séparation logique par IP) :
   - WAN : SSH uniquement vers le bastion ; UDP/1194 depuis le WAN de l'autre site
   - OpenVPN : `10.<local>0.0.0/16` <-> `10.<distant>0.0.0/16` : Pass
   - LAN : web (`.20` de S2) ne peut pas initier vers les autres hôtes

### 2.4 Perte du serveur Proxmox

**Temps estimé : 2-4h**

> Le serveur Proxmox est fourni et géré par l'hébergeur : cette section ne
> s'applique qu'à une reconstruction « from scratch » complète.

1. Installer/réinitialiser Proxmox VE sur le serveur du site
2. Configurer les bridges réseau :
   - `vmbr0` : WAN (IP publique du site)
   - `vmbr132` : LAN du site (`10.<site>0.0.0/24`)
3. (La passerelle LAN est portée par le pfSense, pas par Proxmox)
4. Recréer les VMs pfSense (voir §2.3)
5. Recréer les VMs applicatives (voir §2.1)
6. Déployer toute l'infrastructure :

```bash
make galaxy
make deploy   # déploie l'infra ET met l'IPAM NetBox à jour
```

### 2.5 Compromission du bastion

**Temps estimé : 15-30 min**

1. Isoler immédiatement : couper le VPN

```bash
make killswitch-cut
```

2. Détruire la VM bastion sur Proxmox
3. Recréer la VM et redéployer :

```bash
make deploy-bastion
make deploy-filebeat
```

4. Analyser les logs dans Elasticsearch pour identifier l'étendue de la compromission :

```bash
ssh elastic-s1 'curl -s "http://10.10.0.20:9200/filebeat-site2-*/_search?q=hostname:bastion-s2&size=100&sort=@timestamp:desc" | python3 -m json.tool'
```

5. Restaurer le VPN une fois la remédiation confirmée :

```bash
make killswitch-restore
```

### 2.6 Disque plein sur une VM

**Temps estimé : 5-10 min**

1. Se connecter à la VM :

```bash
ssh <hostname> 'df -h'
```

2. Nettoyer les logs anciens :

```bash
ssh -t <hostname> 'sudo journalctl --vacuum-size=100M'
ssh -t <hostname> 'sudo find /var/log -name "*.gz" -mtime +7 -delete'
```

3. Pour Elasticsearch, supprimer les anciens index :

```bash
ssh elastic-s1 'curl -s "http://10.10.0.20:9200/_cat/indices?v&s=index"'
# Supprimer un index ancien
ssh elastic-s1 'curl -X DELETE "http://10.10.0.20:9200/filebeat-site1-2026.01.01"'
```

## 3. Kill switch - Procédure d'urgence

En cas d'incident de sécurité nécessitant l'isolation immédiate des sites :

```bash
# Couper le VPN inter-sites
make killswitch-cut
```

Cette commande :
- Arrête le serveur OpenVPN sur pfSense S1
- Arrête le client OpenVPN sur pfSense S2
- Vérifie que le tunnel est DOWN
- **Ne modifie pas la configuration** -> recovery instantanée

Pour restaurer :

```bash
make killswitch-restore
```

## 4. Contacts et accès

> Tous les services internes sont atteints via le **bastion S2** (ProxyJump).

| Ressource | Accès |
| --- | --- |
| Proxmox S1 | `https://ns3050272.ip-51-255-76.eu:8006` |
| Proxmox S2 | `https://ns3183326.ip-146-59-253.eu:8006` |
| Bastion S2 (porte d'entrée) | `ssh bastion@<bastion_public_ip>` |
| pfSense S1 | `https://10.10.0.1` (admin, via bastion) |
| pfSense S2 | `https://10.20.0.1` (admin, via bastion) |
| NetBox | `http://10.10.0.10` (admin, via bastion) |
| Elasticsearch | `http://10.10.0.20:9200` (via bastion) |

## 5. Sauvegardes

### Ce qui est sauvegardé par le repo Git

- Toute la configuration Ansible (rôles, playbooks, variables)
- Les secrets chiffrés via `ansible-vault`
- La documentation

### Ce qui n'est PAS sauvegardé (à recréer)

- Les données NetBox (base PostgreSQL)
- Les index Elasticsearch (logs)
- La configuration pfSense (manuelle)
- Les VMs Proxmox elles-mêmes

### Recommandation

- Activer les snapshots Proxmox sur les VMs critiques (netbox-s1, pfSense S1/S2)
- Exporter régulièrement la config pfSense : Diagnostics > Backup & Restore
- Sauvegarder la base NetBox : `pg_dump -U netbox netbox > backup.sql`

## 6. Tests de recovery

| Test | Fréquence recommandée | Commande |
| --- | --- | --- |
| Kill switch cut/restore | Mensuel | `make killswitch-cut && make killswitch-restore` |
| Redéploiement complet | Trimestriel | `make deploy` sur VMs fraîches |
| Vérification des logs | Hebdomadaire | Vérifier les index Elasticsearch |
| Lint du code Ansible | À chaque commit | `make lint` |
