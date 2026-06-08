# Observabilité - analyse de la télémétrie

Ce dossier contient l'**analyse des logs centralisés** et ses visualisations.
Il prouve les exigences `log_analysis` (analyse pertinente) et `log_visuals`
(représentations visuelles).

## Couverture de l'observabilité : logs, métriques, traces

Le sujet attend une observabilité « logs + indicateurs + traces ». Ce que couvre
l'infrastructure, et les choix assumés :

| Pilier | Outil | État | Index ES |
| --- | --- | --- | --- |
| **Logs** | Filebeat (VM) + Remote Syslog (pfSense) | ✅ en place | `filebeat-*`, `pfsense-*` |
| **Métriques** | Metricbeat (CPU, mémoire, disque, réseau) | ✅ en place | `metricbeat-*` |
| **Traces** (APM) | - | ⛔ **écarté volontairement** | - |

**Pourquoi pas de tracing distribué (APM) ?** Choix assumé, pour deux raisons :

1. **Contrainte RAM (2 Gio/VM).** Un serveur APM (Elastic APM / Jaeger) ajoute un
   composant lourd à côté d'Elasticsearch qui sature déjà `elastic-s1`. Il n'y a
   pas de marge mémoire pour l'héberger sans fragiliser un rôle existant.
2. **Pertinence faible ici.** Le tracing distribué sert à suivre une requête à
   travers des **microservices applicatifs**. Cette infrastructure est composée de
   **services d'infrastructure** (NetBox, Elasticsearch, un site statique), pas
   d'une chaîne d'appels applicatifs inter-services : il n'y a pas de transaction
   métier à tracer de bout en bout. Les logs + métriques couvrent les besoins de
   supervision réels (santé, sécurité, charge).

L'observabilité repose donc sur **deux des trois piliers** (logs + métriques),
ce qui est l'optimum atteignable et pertinent dans les contraintes du projet.

## Approche et justification du choix technique

Les logs de tous les composants (4 VM des deux sites) sont collectés par
**Filebeat** et centralisés dans **Elasticsearch** (cluster `cia-logging`,
sur `elastic-s1`). L'**analyse** est réalisée par les **aggregations natives
d'Elasticsearch** ; ce dépôt ne fait qu'envoyer les requêtes et rendre les
résultats.

**Pourquoi pas Kibana ni Grafana ?** Contrainte non négociable du sujet :
**3 VM max par site, 2 Gio de RAM par VM**. Elasticsearch consomme déjà ~830 Mio
sur `elastic-s1` (qui swappe), et aucune autre VM ne peut accueillir un outil de
dashboard (~1,2-1,5 Gio pour Kibana, ~400 Mio en charge pour Grafana) sans
fragiliser un rôle existant (DMZ web, bastion durci, services NetBox). Plutôt que
d'ajouter un outil lourd, on exploite **ES directement** et on rend les résultats
en **HTML + SVG versionnés** : léger, reproductible, et auditables.

## Reproduire l'analyse

```bash
make observability          # ou : python3 scripts/observability.py
```

Le script :
1. ouvre un **tunnel SSH** vers Elasticsearch via le bastion (commande affichée) ;
2. pour **chaque indicateur**, affiche la **requête ES exacte** (équivalent `curl`
   copiable) puis sa réponse - rien n'est simulé, tout est rejouable à la main ;
3. génère `report.html` + des graphes `*.svg` dans ce dossier.

## Indicateurs produits

| Indicateur | Aggregation ES | Intérêt |
| --- | --- | --- |
| Logs par site | `terms` sur `site` | Répartition S1 / S2 |
| Logs par hôte | `terms` sur `host.name` | Qui génère quoi |
| Logs par fichier source | `terms` sur `log.file.path` | auth / syslog / nginx / fail2ban |
| Tentatives SSH échouées par hôte | `match_phrase "Failed password"` + `terms` | Exposition réelle du bastion |
| Top IP attaquantes | extraction `from <ip>` du message | Sources des attaques SSH |
| Volumétrie / jour | `date_histogram` | Tendance, pics d'activité |

> Les chiffres dépendent des données réellement indexées au moment de
> l'exécution. Exemple observé : le bastion (seul exposé sur Internet) concentre
> l'essentiel des tentatives SSH échouées - cohérent avec son rôle de point
> d'entrée, et c'est précisément ce que `fail2ban` filtre.
