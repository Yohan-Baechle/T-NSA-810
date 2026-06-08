#!/usr/bin/env bash
#
# Démonstration d'ajout d'un 3e site (cf. docs/SCALING.md).
# Génère les fichiers du site 3, vérifie qu'Ansible les prend en compte
# (inventaire + syntax-check), puis nettoie. Ne déploie rien.
#
# Usage :
#   ./scripts/add-site-demo.sh          # génère, vérifie, nettoie
#   ./scripts/add-site-demo.sh --keep   # garde les fichiers générés
#   ./scripts/add-site-demo.sh --clean  # supprime les fichiers du site 3
#
set -u
KEEP=0; CLEAN_ONLY=0
for a in "$@"; do case "$a" in
  --keep) KEEP=1 ;;
  --clean) CLEAN_ONLY=1 ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANS="$REPO_DIR/ansible"
INV="$ANS/inventory"
[ -t 1 ] && { G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; GR=$'\e[90m'; BD=$'\e[1m'; R=$'\e[31m'; X=$'\e[0m'; } \
        || { G=''; Y=''; C=''; GR=''; BD=''; R=''; X=''; }

# Fichiers créés/modifiés pour le site 3
S3_GROUPVARS="$INV/group_vars/site3.yml"
S3_HOSTVARS="$INV/host_vars/web-s3.yml"
VARS="$INV/group_vars/all/vars.yml"
HOSTS="$INV/hosts.yml"
BACKUP="$INV/.add-site-demo.bak"   # sauvegarde de vars.yml + hosts.yml

step()  { printf "\n${BD}${C}▶ %s${X}\n" "$1"; }
show()  { printf "    ${C}\$ %s${X}\n" "$1"; eval "$1" 2>&1 | sed "s/^/      ${GR}│${X} /"; }
ok()    { printf "  ${G}✔${X} %s\n" "$1"; }
note()  { printf "  ${GR}%s${X}\n" "$1"; }

clean() {
  rm -f "$S3_GROUPVARS" "$S3_HOSTVARS"
  if [ -f "$BACKUP/vars.yml" ]; then cp "$BACKUP/vars.yml" "$VARS"; fi
  if [ -f "$BACKUP/hosts.yml" ]; then cp "$BACKUP/hosts.yml" "$HOSTS"; fi
  rm -rf "$BACKUP"
}

if [ "$CLEAN_ONLY" = 1 ]; then
  step "Nettoyage : retour à l'état 2 sites"
  clean; ok "Fichiers du site 3 supprimés, vars.yml/hosts.yml restaurés"
  show "cd $ANS && ansible-inventory --graph 2>/dev/null | grep -E 'site[0-9]'"
  exit 0
fi

printf "${BD}${C}"
cat <<'BANNER'
  Ajout d'un 3e site - démonstration de scalabilité (dry-run)
BANNER
printf "${X}${GR}  Référence : docs/SCALING.md${X}\n"

# --- État de départ -----------------------------------------------------------
step "0. État actuel : 2 sites (source de vérité Ansible)"
show "cd $ANS && ansible-inventory --graph 2>/dev/null | grep -E '@(site|all)|--'"

# Sauvegarde avant modification (pour restaurer à l'identique)
mkdir -p "$BACKUP"; cp "$VARS" "$BACKUP/vars.yml"; cp "$HOSTS" "$BACKUP/hosts.yml"

# --- Étape 1 : déclarer le site dans vars.yml ---------------------------------
step "1. Déclarer le site 3 dans la source de vérité (group_vars/all/vars.yml)"
# Ajoute site3 sous 'sites:' (après le bloc site2) et son domaine DNS.
python3 - "$VARS" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
if "site3:" not in s:
    # insère site3 juste après le bloc site2 (même indentation que site1/site2)
    s = re.sub(r'(  site2:\n(?:    .*\n)+)',
               r'\1  site3:\n    supernet: "10.30.0.0/16"\n    lan: "10.30.0.0/24"\n',
               s, count=1)
if "dns_domain_site3:" not in s:
    s = s.replace("dns_domain_site2: site2.lan",
                  "dns_domain_site2: site2.lan\ndns_domain_site3: site3.lan")
open(p, "w").write(s)
PY
show "grep -A2 'site3:' $VARS"
show "grep 'dns_domain_site3' $VARS"
ok "Site 3 déclaré : supernet 10.30.0.0/16, domaine site3.lan"

# --- Étape 2 : group_vars du site --------------------------------------------
step "2. Créer le group_vars du site (copie du gabarit site2.yml)"
cat > "$S3_GROUPVARS" <<'YAML'
---
# Site 3 (nouveau) - supernet 10.30.0.0/16
site_name: site3
site_supernet: "{{ sites.site3.supernet }}"
site_domain: "{{ dns_domain_site3 }}"
site_dns: "10.30.0.1"   # interface Admin du pfSense S3 (resolver + forwarding)
YAML
show "cat $S3_GROUPVARS"
ok "group_vars/site3.yml créé"

# --- Étape 3 : hosts + host_vars ---------------------------------------------
step "3. Ajouter le groupe site3 et ses hôtes à l'inventaire"
python3 - "$HOSTS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "site3:" not in s:
    block = ("    site3:\n"
             "      hosts:\n"
             "        web-s3:\n"
             "          ansible_host: 10.30.0.20\n"
             "          ansible_user: web\n")
    s = s.rstrip() + "\n" + block
open(p, "w").write(s)
PY
cat > "$S3_HOSTVARS" <<'YAML'
---
# Web interne du site 3 - même profil que web-s2 (zone dmz).
host_zone: dmz
host_prefix: 24
host_gateway: "10.30.0.1"
host_lan_ip: "10.30.0.20"
YAML
show "tail -6 $HOSTS"
show "cat $S3_HOSTVARS"
ok "Groupe site3 + host_vars/web-s3.yml ajoutés"

# --- Preuve : Ansible reconnaît le site 3 ------------------------------------
step "4. PREUVE - Ansible prend le site 3 en compte (sans rien déployer)"
show "cd $ANS && ansible-inventory --graph 2>/dev/null | grep -E '@(site|all)|--'"
note "-> site3 et web-s3 apparaissent dans l'inventaire."

show "cd $ANS && ansible-inventory --host web-s3 2>/dev/null"
note "-> les variables (zone, gateway, domaine, supernet) sont résolues pour le nouvel hôte."

step "5. PREUVE - la syntaxe des playbooks reste valide avec le site 3"
if cd "$ANS" && ansible-playbook playbooks/site.yml --syntax-check >/tmp/_s3check 2>&1; then
  ok "ansible-playbook site.yml --syntax-check : OK (site 3 intégré sans erreur)"
else
  printf "  ${R}✘ syntax-check a échoué :${X}\n"; sed 's/^/      /' /tmp/_s3check
fi

# --- Reste à faire hors Ansible ----------------------------------
step "Reste à faire pour un site RÉEL (hors périmètre de cette démo)"
note "- Créer la VM pfSense S3 + interfaces de zone (manuel, cf. docs/pfsense-setup.md)"
note "- Étendre le VPN : annoncer 10.30.0.0/16 (une seule route par site)"
note "- netbox-populate.yml + killswitch.yml : ajouter le site (IP pfSense en dur)"
note "- Puis : make deploy  (configure les VMs du site 3 + met l'IPAM à jour)"

# --- Nettoyage ---------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  printf "\n${Y}● --keep : fichiers du site 3 conservés. Nettoyer avec :${X}\n"
  printf "    ./scripts/add-site-demo.sh --clean\n"
else
  step "Nettoyage automatique (retour à l'état 2 sites)"
  clean; ok "État restauré : la démo n'a laissé aucune trace"
  show "cd $ANS && ansible-inventory --graph 2>/dev/null | grep -E 'site[0-9]'"
fi
