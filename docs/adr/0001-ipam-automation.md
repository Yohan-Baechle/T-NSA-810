# ADR 0001 - Mise à jour automatique de l'IPAM (NetBox)

- **Statut** : accepté
- **Contexte CDC** : « Automate IP management via an IPAM (NetBox) and **keep the IPAM up to date** » / « **Automatically updated IPAM** ».

## Contexte

Le cahier des charges exige un IPAM (NetBox) **maintenu à jour automatiquement** :
l'inventaire des sites, préfixes, devices et adresses ne doit pas être saisi à la
main dans l'interface NetBox, où il dériverait inévitablement de la réalité.

La question est : **quelle est la source de vérité, et comment l'IPAM en découle.**

## Décision

**La source de vérité est le code Ansible** (inventaire + variables :
`inventory/`, `group_vars/all/vars.yml`, et la liste des devices/préfixes dans
`playbooks/netbox-populate.yml`). NetBox est un **miroir** alimenté depuis cette
source, pas l'inverse.

Le peuplement est **déclaratif et idempotent** (modules `netbox.netbox.*` avec
`state: present`) et il est **rejoué automatiquement à chaque déploiement** :
`playbooks/site.yml` enchaîne, après le déploiement de l'infra, la création du
token API (`netbox-token.yml`) puis le peuplement (`netbox-populate.yml`).

Concrètement : **`make deploy` met l'IPAM à jour dans le même geste**, sans
intervention manuelle. Un `make netbox-populate` reste disponible pour rejouer
l'IPAM seul (ex. correction de données sans redéploiement complet).

## Pourquoi « automatique » au sens du CDC

- **Aucune saisie manuelle** dans NetBox : tout vient du code versionné.
- **Pas de dérive** : le re-run idempotent réaligne NetBox sur la source à chaque
  déploiement ; rejouer ne crée jamais de doublon.
- **Reproductible et auditable** : l'état de l'IPAM est entièrement déductible du
  dépôt Git (revue par PR, historique, CODEOWNERS).

## Alternatives écartées

- **Inventaire dynamique NetBox** (`nb_inventory` - Ansible *lit* depuis NetBox).
  Rejeté : cela **inverse la source de vérité** (il faudrait alors peupler NetBox
  à la main *avant* de déployer), ce qui recrée précisément le risque de dérive
  que l'on cherche à éviter, et alourdit l'architecture sans bénéfice ici.

- **Hook CI (GitHub Actions) déclenché sur push.** Rejeté **dans l'état actuel** :
  l'infrastructure est privée (OVH + bastion), sans runner self-hosted capable de
  joindre le bastion et le vault. Un workflow CI serait du décor non exécutable.

- **Cron sur netbox-s1.** Rejeté : la source de vérité est dans Git, pas sur la VM ;
  un cron local rejouerait en boucle un état inchangé (bruit) sans jamais voir les
  changements de code.

## Évolution possible (si l'infra grandit)

Le jour où un **runner self-hosted** atteint le réseau interne, le même
`netbox-populate.yml` peut être déclenché par un **workflow CI** sur tout push
modifiant l'inventaire ou les variables - passant d'« automatique au déploiement »
à « automatique sur changement ». Aucune réécriture nécessaire : seul le
déclencheur change.
