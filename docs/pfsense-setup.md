# Configuration pfSense - interconnexion des 2 sites (VPN site-to-site)

Objectif : monter le tunnel OpenVPN entre S1 (serveur) et S2 (client) pour que
les réseaux `10.10.0.0/16` et `10.20.0.0/16` communiquent.

> **État : validé.** Le tunnel est up des deux côtés et le routage LAN<->LAN
> fonctionne (`ping 10.10.0.1` depuis le LAN de S2 -> 0% packet loss).

## Topologie réseau (Proxmox)

Chaque pfSense a 2 interfaces : `net0`/`vmbr0` = WAN public, `net1`/`vmbr132` =
LAN. Les VM applicatives du site partagent ce même `vmbr132` (bridge local au
node, distinct entre les deux sites). Le LAN est **plat par site** (`/24`) ; la
séparation des zones est **logique** (règles pfSense entre IP), les nodes
n'exposant qu'un seul bridge LAN.

## Paramètres de référence

| | pfSense S1 (VM 117, node vm3) | pfSense S2 (VM 159, node vm004) |
| --- | --- | --- |
| WAN (IP publique) | `5.196.45.2/24` | `5.135.202.79/24` |
| Supernet LAN | `10.10.0.0/16` | `10.20.0.0/16` |
| LAN pfSense (gw) | `10.10.0.1/24` | `10.20.0.1/24` |
| Bridge LAN | `vmbr132` | `vmbr132` |
| Rôle OpenVPN | **Serveur** | **Client** |
| Tunnel | `10.0.0.1` | `10.0.0.2` |

| Tunnel | Valeur |
| --- | --- |
| Réseau du tunnel | `10.0.0.0/30` |
| Protocole / port | UDP4 / `1194` |
| Chiffrement | AES-256-GCM, Auth SHA256 |

---

## Étape 1 - Vérifier la connectivité WAN

Sur chaque pfSense : **Status > Interfaces**, confirmer l'IP WAN.
Depuis S2, vérifier que le WAN de S1 répond :

- **Diagnostics > Ping**, Host = `5.196.45.2`, Source = WAN.

Si le ping échoue, vérifier qu'aucune règle/upstream ne bloque l'ICMP ; le VPN
n'a de toute façon besoin que de l'UDP/1194 ouvert vers S1 (étape 5).

## Étape 2 - Autorité de certification (sur S1)

**System > Cert. Manager > CAs > Add**

- Descriptive name : `CIA-CA`
- Method : *Create an internal Certificate Authority*
- Key type : RSA 2048 (ou ECDSA), Digest : SHA256
- Common Name : `CIA-CA`

## Étape 3 - Certificat serveur (sur S1)

**System > Cert. Manager > Certificates > Add**

- Method : *Create an internal Certificate*
- Descriptive name : `openvpn-server-s1`
- CA : `CIA-CA`
- Type : **Server Certificate**
- Common Name : `openvpn-server-s1`

## Étape 4 - Serveur OpenVPN (sur S1)

**VPN > OpenVPN > Servers > Add**

- Server mode : **Peer to Peer (SSL/TLS)**
- Protocol : `UDP on IPv4 only`
- Device mode : `tun`
- Interface : `WAN`
- Local port : `1194`
- TLS Authentication : activé (générer la clé TLS, à réimporter sur S2)
- Peer Certificate Authority : `CIA-CA`
- Server certificate : `openvpn-server-s1`
- **IPv4 Tunnel Network** : `10.0.0.0/30`
- **IPv4 Local network(s)** : `10.10.0.0/16`   ← réseaux de S1 annoncés au client
- **IPv4 Remote network(s)** : `10.20.0.0/16`  ← réseaux de S2 routés via le tunnel
- Data Encryption Algorithms : `AES-256-GCM`
- Auth digest : `SHA256`

> Noter le contenu de la CA, du certificat serveur et de la clé TLS : ils seront
> importés sur S2.

## Étape 5 - Règles firewall sur S1

**Firewall > Rules > WAN > Add** (autoriser l'arrivée du client) :
- Protocol UDP, Destination port `1194`, Destination = WAN address, Source =
  `5.135.202.79` (WAN de S2) -> Pass.

**Firewall > Rules > OpenVPN > Add** (autoriser le trafic dans le tunnel) :
- Protocol any, Source `10.20.0.0/16`, Destination `10.10.0.0/16` -> Pass.

## Étape 6 - Importer la CA et le certificat client (sur S2)

**System > Cert. Manager > CAs > Add** : *Import an existing CA*, coller le
certificat de `CIA-CA` (depuis S1).

**System > Cert. Manager > Certificates > Add** : créer/importer un certificat
client `openvpn-client-s2` signé par `CIA-CA`. (Le plus simple : créer le client
sur S1 puis l'exporter, ou créer un certificat utilisateur sur S1.)

## Étape 7 - Client OpenVPN (sur S2)

**VPN > OpenVPN > Clients > Add**

- Server mode : **Peer to Peer (SSL/TLS)**
- Protocol : `UDP on IPv4 only`
- Interface : `WAN`
- **Server host or address** : `5.196.45.2`
- Server port : `1194`
- TLS Authentication : coller la clé TLS de S1
- Peer Certificate Authority : `CIA-CA` (importée)
- Client certificate : `openvpn-client-s2`
- **IPv4 Tunnel Network** : `10.0.0.0/30`
- **IPv4 Remote network(s)** : `10.10.0.0/16`  ← réseaux de S1 routés via le tunnel
- Data Encryption Algorithms : `AES-256-GCM`
- Auth digest : `SHA256`

## Étape 8 - Règles firewall sur S2

**Firewall > Rules > OpenVPN > Add** :
- Protocol any, Source `10.10.0.0/16`, Destination `10.20.0.0/16` -> Pass.

## Étape 9 - Vérification

- S1 : **Status > OpenVPN** -> le serveur doit indiquer le client connecté.
- S2 : **Status > OpenVPN** -> état `up`.
- S2 : **Diagnostics > Ping**, Host = `10.0.0.1`, Source = `WAN`/`LAN` -> réponse.
- Ping inter-LAN : depuis une VM de S2 vers `10.10.0.10` (NetBox) doit passer.

Le kill switch (`make killswitch-cut` / `restore`) coupe/relance ce serveur et ce
client OpenVPN sans toucher à la configuration (cf. `playbooks/killswitch.yml`).

---

## Étape 10 - Accès à l'admin pfSense (sans désactiver le firewall)

Par défaut le firewall WAN bloque l'accès au webConfigurator. Plutôt que de
désactiver `pf` (ce qui casse NAT/VPN/port-forward), autoriser l'IP d'admin :

**Firewall > Rules > WAN > Add** (sur chaque pfSense) :
- Pass / TCP / Source = `<IP publique de l'admin>` / Dest = `WAN address` / Port `443`
- (optionnel) une 2e règle identique sur le port `22` pour le SSH d'admin

Le webConfigurator est en HTTPS (certificat auto-signé : avertissement navigateur
normal). Ne jamais lancer `pfctl -d` - le firewall doit rester actif en permanence.

## Étape 11 - DNS forwarding inter-sites

Objectif : résoudre par nom les machines de l'autre site (ex. depuis S1,
`web-s2.site2.lan` -> `10.20.0.20`).

> Domaines internes en **`.lan`** (pas `.local`, réservé au mDNS et non
> forwardable proprement par Unbound). Source de vérité : `dns_domain_site1` /
> `dns_domain_site2` dans `group_vars/all/vars.yml`.

Sur **chaque** pfSense, `Services > DNS Resolver > General Settings` :

1. **Enable** le resolver ; **Network Interfaces** = `All` (écoute aussi sur le
   tunnel). **Outgoing Network Interfaces** = **`LAN` uniquement** ⚠️ - point
   critique : en `All`, Unbound forwarde avec l'IP source du tunnel (10.0.0.1)
   que l'autre site ne route pas en retour -> SERVFAIL/timeout. Forcé sur `LAN`,
   il émet depuis l'IP LAN (10.10.0.1 / 10.20.0.1), routée via le VPN.
2. **DNSSEC** : activé. Les zones internes `.lan` sont non signées -> déclarées
   `domain-insecure` (cf. Custom options) pour que la validation ne casse pas.
3. **Host Overrides** - déclarer les hôtes du site local :
   - S1 : `netbox-s1`/`elastic-s1`/`pf1` en `site1.lan` (10.10.0.10/.20/.1)
   - S2 : `bastion-s2`/`web-s2`/`pf2` en `site2.lan` (10.20.0.10/.20/.1)
4. **Domain Overrides** - forwarder le domaine de l'autre site via le VPN :
   - S1 : `site2.lan` -> `10.20.0.1`
   - S2 : `site1.lan` -> `10.10.0.1`
5. **Access Lists** - autoriser les requêtes DNS venant de l'autre site :
   - S1 : Allow `10.20.0.0/16`
   - S2 : Allow `10.10.0.0/16`
6. **Custom options** - laisser passer la requête vers le forward-zone
   (`transparent`) et exempter la zone interne de DNSSEC (`domain-insecure`) :
   - S1 :
     ```
     server:
     local-zone: "site2.lan." transparent
     domain-insecure: "site2.lan."
     ```
   - S2 :
     ```
     server:
     local-zone: "site1.lan." transparent
     domain-insecure: "site1.lan."
     ```

Save + **Apply Changes** des deux côtés.

### Vérification

```bash
# depuis pfSense S1 (Diagnostics > Command Prompt)
drill web-s2.site2.lan @127.0.0.1     # -> 10.20.0.20, rcode NOERROR

# depuis une VM (résolution bout-en-bout)
getent hosts web-s2.site2.lan         # depuis S1 -> 10.20.0.20
getent hosts netbox-s1.site1.lan      # depuis S2 -> 10.10.0.10
```

---

## Étape 12 - Remote Syslog pfSense -> Elasticsearch (centralisation des logs)

Objectif : faire remonter les logs des **deux pfSense** dans Elasticsearch, pour
que la centralisation couvre *tous* les composants (firewalls inclus), pas
seulement les VM.

pfSense (FreeBSD) ne peut pas héberger Filebeat. On utilise donc le **Remote
Syslog** intégré de pfSense, qui pousse les logs en UDP vers un **collecteur** :
la VM `netbox-s1` (`10.10.0.10`), où Filebeat écoute en UDP/514 (input `syslog`,
activé par `filebeat_syslog_collector: true` dans son `host_vars`). Filebeat
route ces logs vers l'index dédié **`pfsense-<date>`**.

### Côté collecteur (déjà fait par Ansible)

`make deploy-filebeat` configure netbox-s1 pour écouter en UDP/514 et router les
logs pfSense vers `pfsense-*`. Rien à faire manuellement côté VM.

### Côté pfSense (S1 et S2)

`Status > System Logs > Settings`, section **Remote Logging Options** :

1. ☑ **Enable Remote Logging**
2. **Source Address** : `LAN` (pour sortir avec l'IP LAN, routée par le VPN -
   même logique que le DNS forwarding).
3. **Remote log servers** : `10.10.0.10:514`
4. **Remote Syslog Contents** : cocher au minimum **Firewall Events** (et
   System / DNS si souhaité).
5. **Save**.

> S2 envoie vers `10.10.0.10` à travers le tunnel VPN. Vérifier que la règle
> firewall OpenVPN autorise déjà `10.20.0.0/16 -> 10.10.0.0/16` (c'est le cas avec
> la règle posée à l'étape 8). Le port UDP/514 est couvert par la règle `any`.

### Vérification

```bash
# Sur netbox-s1 : le port 514/udp est ouvert (Filebeat collecteur)
ss -ulnp | grep 514

# Dans Elasticsearch : l'index pfsense-* se remplit
curl -s 'http://10.10.0.20:9200/_cat/indices/pfsense-*?v'

# Générer un événement : se connecter au webConfigurator d'un pfSense,
# provoquer un blocage firewall, puis vérifier l'arrivée des logs :
curl -s 'http://10.10.0.20:9200/pfsense-*/_search?size=1&sort=@timestamp:desc'
```
