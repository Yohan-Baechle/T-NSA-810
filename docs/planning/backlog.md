# Backlog - Projet CIA (T-NSA-810)

> Source : suivi ClickUp. Soutenance : **25 juin 2026**.
> Avancement : **31/38** items terminés.

## Équipe & domaines (OBS)

| Membre | Domaine principal | Périmètre |
|---|---|---|
| **Yohan Baechlé** | Orchestration / Ops / Qualité | Socle Ansible, CI, kill switch, DRP, Makefile, validation E2E, planning |
| **Lena Gonzalez Breton** | Réseau / Front | Inventaire & adressage, pfSense, VPN site-to-site, DNS, site web, rôle `common` |
| **Lothaire Nobili** | Sécurité / IPAM | Bastion durci, ansible-vault, NetBox (IPAM) + auto-MAJ, orchestration `site.yml` |
| **Fat2Nash** | Observabilité | Elasticsearch, Filebeat, Metricbeat, analyse télémétrie + visualisations |

## Sprint 1 - Scoping (Follow-up 1)

| Tâche | Responsable | Échéance | Statut | Tag |
|---|---|---|---|---|
| Setup repositories GitOps | Yohan | 2026-01-28 | ✅ Fait | `gitops` |
| Hardware Requirements | Lena | 2026-01-30 | ✅ Fait | `hardware` |
| Exploration technologique initiale | Équipe | 2026-02-03 | ✅ Fait | `research` |
| Matrice RACI (OBS<->WBS) | Yohan | 2026-02-05 | ✅ Fait | `quality` |
| Quality Plan | Yohan | 2026-02-10 | ✅ Fait | `quality` |
| Software Functional Requirement | Lothaire | 2026-02-12 | ✅ Fait | `doc` |
| Stratégie de test | Yohan | 2026-02-14 | ✅ Fait | `testing` |
| PBS / WBS | Équipe | 2026-02-19 | ✅ Fait | `doc` |
| Création du Gantt chart | Yohan | 2026-02-20 | ✅ Fait | `planning` |
| Découpage en tickets (Backlog) | Yohan | 2026-02-24 | ✅ Fait | `planning` |
| Requirements fonctionnels détaillés | Lothaire | 2026-02-26 | ✅ Fait | `requirements` |
| Diagramme d'infrastructure (V1) | Lena | 2026-03-03 | ✅ Fait | `doc` |
| Reporting blockers / Liste tickets FU2 | Yohan | 2026-03-10 | ✅ Fait | `reporting` |
| 🏁 MILESTONE Follow-up 1 (Scoping) | Équipe | 2026-03-13 | ✅ Fait | `milestone` |

## Sprint 2 - First Building Blocks (Follow-up 2)

| Tâche | Responsable | Échéance | Statut | Tag |
|---|---|---|---|---|
| Installation Proxmox VE S1 + S2 | Lena | 2026-04-08 | ✅ Fait | `infra` |
| Déploiement pfSense S1 + S2 | Lena | 2026-04-15 | ✅ Fait | `firewall` |
| Configuration VPN Site-to-Site | Lena | 2026-04-22 | ✅ Fait | `vpn` |
| Firewall avancé + Kill Switch | Yohan | 2026-04-29 | ✅ Fait | `security` |
| Premiers fichiers IaC (Ansible) | Lothaire | 2026-05-06 | ✅ Fait | `iac` |
| MAJ Gantt / Reporting / tickets FU3 | Yohan | 2026-05-18 | ✅ Fait | `planning` |
| 🏁 MILESTONE Follow-up 2 | Équipe | 2026-05-20 | ✅ Fait | `milestone` |

## Sprint 3 - Beta (Follow-up 3)

| Tâche | Responsable | Échéance | Statut | Tag |
|---|---|---|---|---|
| Déploiement Bastion Host | Lothaire | 2026-05-25 | ✅ Fait | `security` |
| Déploiement NetBox (IPAM) + auto-MAJ | Lothaire | 2026-05-29 | ✅ Fait | `ipam` |
| Déploiement Elasticsearch | Nash | 2026-06-02 | ✅ Fait | `observability` |
| Collecte logs (Filebeat + pfSense syslog) | Nash | 2026-06-04 | ✅ Fait | `logs` |
| Déploiement Website Interne | Lena | 2026-06-08 | ✅ Fait | `web` |
| Configuration DNS Forwarding | Lena | 2026-06-10 | 🔄 En cours | `dns` |
| Liste finale choix technos / MAJ Gantt | Yohan | 2026-06-13 | ✅ Fait | `planning` |
| Reporting blockers S3 | Yohan | 2026-06-14 | 🔄 En cours | `reporting` |
| 🏁 MILESTONE Follow-up 3 (Beta) | Équipe | 2026-06-15 | 🔄 En cours | `milestone` |

## Sprint 4 - Keynote Final

| Tâche | Responsable | Échéance | Statut | Tag |
|---|---|---|---|---|
| Secure credential store (Vault) | Lothaire | 2026-06-17 | ✅ Fait | `security` |
| Code source versionné (réseau + logs) | Équipe | 2026-06-17 | ✅ Fait | `code` |
| Diagramme d'infrastructure final | Lena | 2026-06-19 | ✅ Fait | `doc` |
| Document technique détaillé | Lothaire | 2026-06-19 | 🔄 En cours | `doc` |
| Documentation DRP / Runbooks | Yohan | 2026-06-20 | ✅ Fait | `drp` |
| Tests d'intégration complets | Yohan | 2026-06-22 | 🔄 En cours | `testing` |
| Préparation présentation Keynote | Équipe | 2026-06-23 | ⬜ À faire | `presentation` |
| 🏁 KEYNOTE - Présentation Finale | Équipe | 2026-06-25 | ⬜ À faire | `milestone` |
