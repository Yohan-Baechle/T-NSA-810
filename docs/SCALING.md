# Scalabilité - ajout d'un nouveau site

L'architecture est conçue pour intégrer rapidement de nouveaux sites. Le plan
d'adressage suit le motif **`10.<N0>.0.0/16` réservé par site**, avec un LAN
`/24` actif par site (gateway pfSense = `.1`).

| Site | Bloc agrégé (réservé) | LAN actif | Gateway |
| ---- | --------------------- | --------- | ------- |
| S1 | `10.10.0.0/16` | `10.10.0.0/24` | `10.10.0.1` |
| S2 | `10.20.0.0/16` | `10.20.0.0/24` | `10.20.0.1` |
| **S3 (nouveau)** | `10.30.0.0/16` | `10.30.0.0/24` | `10.30.0.1` |

Comme chaque site est un `/16` agrégé, le VPN n'annonce **qu'une seule route par
site** : ajouter S3 = ajouter une route `10.30.0.0/16`.

> La séparation des zones (admin/services/dmz) est logique (règles pfSense entre
> IP) tant que les nodes Proxmox n'exposent qu'un bridge LAN. Le `/16` réservé
> permet de basculer en VLAN par zone si un accès à la config réseau des nodes
> devient disponible.

## Procédure (exemple : site 3)

### 1. Déclarer le site dans la source de vérité

`ansible/inventory/group_vars/all/vars.yml` - ajouter sous `sites:` :

```yaml
  site3:
    supernet: "10.30.0.0/16"
    lan: "10.30.0.0/24"
```

(L'IP publique WAN du site se configure côté pfSense, pas dans Ansible.)

### 2. Créer le group_vars du site

`ansible/inventory/group_vars/site3.yml` (copier `site2.yml` comme gabarit) :

```yaml
site_name: site3
site_supernet: "{{ sites.site3.supernet }}"
site_domain: "{{ dns_domain_site3 }}"
site_dns: "10.30.0.1"
```

Ajouter `dns_domain_site3: site3.lan` dans `vars.yml` et l'ajouter aux
`search` du template netplan si la résolution inter-sites doit l'inclure.

### 3. Ajouter les hosts à l'inventaire

`ansible/inventory/hosts.yml` - nouveau groupe `site3:` avec ses VM, puis un
`host_vars/<host>.yml` par VM précisant `host_zone`, `host_prefix`,
`host_gateway` (gateway = interface pfSense de la zone).

### 4. Réseau & pfSense du site 3

- Créer la VM pfSense S3 + ses interfaces de zone (cf. `docs/infra.md` §3).
- Étendre le VPN : annoncer `10.30.0.0/16` vers les sites existants et
  inversement (full-mesh ou hub-and-spoke selon la topologie retenue).
- Configurer NAT outbound, DNS resolver + forwarding inter-sites.

### 5. Mettre à jour les opérations multi-sites

- `ansible/playbooks/killswitch.yml` : ajouter une variable `pfsense_s3` et la
  paire de tâches cut/restore correspondante (les IP pfSense y sont en dur).
- `ansible/playbooks/netbox-populate.yml` : ajouter le site, ses prefixes de
  zone et ses devices (l'IPAM reste la source de vérité).

### 6. Déployer

```bash
make deploy   # applique common + rôles aux nouveaux hosts, puis met l'IPAM à jour
```

(`make deploy` enchaîne le peuplement NetBox ; `make netbox-populate` reste
disponible pour rejouer l'IPAM seul.)

## Pistes d'amélioration (refactoring futur)

- Rendre les playbooks et `netbox-populate` **pilotés par la structure `sites`**
  (boucles sur `sites` / les groupes d'inventaire) plutôt que par des hôtes
  nommés en dur, pour qu'un nouveau site soit pris en compte sans éditer les
  playbooks.
- Inventaire dynamique NetBox (`netbox.netbox.nb_inventory`) : NetBox devient
  alors la source unique et l'inventaire Ansible se génère automatiquement.
