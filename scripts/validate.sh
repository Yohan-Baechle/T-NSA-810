#!/usr/bin/env bash
#
# Validation de bout en bout de l'infrastructure.
# Chaque test affiche la commande qu'il lance puis sa sortie.
#
# Usage :
#   ./scripts/validate.sh                       # menu interactif
#   ./scripts/validate.sh --all [--quick]       # tout (sans les tests lents)
#   ./scripts/validate.sh 4 5 7                 # sections choisies
#   ./scripts/validate.sh --all --destructive   # inclut le test kill switch
#
set -u

# ---------------------------------------------------------------------------
# Paramètres de l'infra (source de vérité : ansible/inventory)
# ---------------------------------------------------------------------------
BASTION_HOST="5.135.202.79"; BASTION_PORT="2222"; BASTION_USER="bastion"
SSH_KEY="${HOME}/.ssh/cia_ansible"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

declare -A VM_IP=(   [netbox-s1]="10.10.0.10" [elastic-s1]="10.10.0.20" [web-s2]="10.20.0.20" )
declare -A VM_USER=( [netbox-s1]="netbox"     [elastic-s1]="elastic"    [web-s2]="web" )

PF1_LAN="10.10.0.1"; PF2_LAN="10.20.0.1"
BASTION_LAN="10.20.0.10"
ES_HOST="10.10.0.20"; ES_PORT="9200"
SYSLOG_COLLECTOR="10.10.0.10"
DOM_S1="site1.lan"; DOM_S2="site2.lan"

SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR"
PROXY="-o ProxyJump=cia-bastion"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
QUICK=0; USE_COLOR=1; RAW=0; DESTRUCTIVE=0; RUN_ALL=0
SELECTED=()
for a in "$@"; do case "$a" in
  --quick) QUICK=1 ;;
  --raw) RAW=1 ;;
  --destructive) DESTRUCTIVE=1 ;;
  --all) RUN_ALL=1 ;;
  --no-color) USE_COLOR=0 ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  [0-9]*) SELECTED+=("$a") ;;
esac; done
[ -t 1 ] || USE_COLOR=0

if [ "$USE_COLOR" = 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; GR=$'\e[90m'; BD=$'\e[1m'; X=$'\e[0m'
else R=''; G=''; Y=''; B=''; C=''; GR=''; BD=''; X=''; fi
CHECK="${G}✔${X}"; CROSS="${R}✘${X}"; WARN="${Y}●${X}"

PASS=0; FAIL=0; SKIP=0
FAILED_TESTS=(); LAST_OUT=""

hdr() { printf "\n${BD}${B}▶ %s${X}\n" "$1"; printf "${GR}%s${X}\n" "──────────────────────────────────────────────────────────────"; }

# run "<cmd>" : affiche la commande, l'exécute, stocke/affiche la sortie réelle.
run() {
  local cmd="$1"
  printf "    ${C}\$ %s${X}\n" "$cmd"
  LAST_OUT="$(eval "$cmd" 2>&1)"; local rc=$?
  if [ -n "$LAST_OUT" ]; then
    if [ "$RAW" = 1 ]; then printf '%s\n' "$LAST_OUT" | sed "s/^/      ${GR}│${X} /"
    else printf '%s\n' "$LAST_OUT" | head -4 | sed "s/^/      ${GR}│${X} /"
      [ "$(printf '%s\n' "$LAST_OUT" | wc -l)" -gt 4 ] && printf "      ${GR}│ …${X}\n"; fi
  else printf "      ${GR}│ (pas de sortie, rc=%d)${X}\n" "$rc"; fi
  return $rc
}

ssh_vm()       { printf 'ssh %s %s -i %s %s@%s %q' "$SSH_OPTS" "$PROXY" "$SSH_KEY" "${VM_USER[$1]}" "${VM_IP[$1]}" "$2"; }
ssh_bastion()  { printf 'ssh %s -i %s -p %s %s@%s %q' "$SSH_OPTS" "$SSH_KEY" "$BASTION_PORT" "$BASTION_USER" "$BASTION_HOST" "$1"; }

ok()   { PASS=$((PASS+1)); printf "  ${CHECK} ${GR}[%-18s]${X} %s\n" "$1" "$2"; return 0; }
ko()   { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1 - $2"); printf "  ${CROSS} ${GR}[%-18s]${X} ${R}%s${X}\n" "$1" "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf "  ${WARN} ${GR}[%-18s]${X} ${Y}%s (ignoré)${X}\n" "$1" "$2"; }

# Récupère le token NetBox depuis le vault (pour tester l'IPAM peuplé).
get_nb_token() {
  [ -f "$REPO_DIR/ansible/vault_password.txt" ] || { echo ""; return; }
  ( cd "$REPO_DIR/ansible" && ansible-vault view inventory/group_vars/all/vault.yml \
      --vault-password-file vault_password.txt 2>/dev/null \
    | grep vault_netbox_api_token | awk '{print $2}' | tr -d '"' )
}

# ===========================================================================
# Définition des sections (numéro -> fonction)
# ===========================================================================

sec0() {
hdr "0. Pré-requis locaux (clé SSH, config)"
run "ls -l $SSH_KEY 2>&1; stat -c '%a' $SSH_KEY 2>/dev/null"
if printf '%s' "$LAST_OUT" | grep -q "No such file"; then ko "setup" "Clé SSH absente : $SSH_KEY"
elif printf '%s' "$LAST_OUT" | tail -1 | grep -qx "600"; then ok "setup" "Clé SSH présente, permissions 600"
else ko "setup" "Clé SSH permissions != 600 (chmod 600 $SSH_KEY)"; fi
run "grep -A1 'Host cia-bastion' ~/.ssh/config 2>/dev/null | head -3"
printf '%s' "$LAST_OUT" | grep -q "cia-bastion" && ok "setup" "Alias cia-bastion présent" || ko "setup" "Alias cia-bastion manquant"
}

sec1() {
hdr "1. Bastion - entrée publique du site distant"
run "$(ssh_bastion 'echo CONNECTED as $(whoami) on $(hostname)')"
if printf '%s' "$LAST_OUT" | grep -q "CONNECTED"; then
  ok "sec_bastion" "SSH bastion réussi par clé"; ok "network_spec2" "Site distant joignable de l'extérieur via bastion"
else ko "sec_bastion" "Connexion bastion échouée"; fi
run "ssh $SSH_OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password -p $BASTION_PORT $BASTION_USER@$BASTION_HOST true; echo rc=\$?"
printf '%s' "$LAST_OUT" | grep -qiE "permission denied|publickey|no supported auth" \
  && ok "sec_access" "Bastion refuse l'auth par mot de passe (clé only)" \
  || ko "sec_access" "Le bastion accepte autre chose que la clé"
}

sec2() {
hdr "2. Isolation - VM internes non exposées"
for vm in netbox-s1 elastic-s1 web-s2; do
  run "timeout 8 ssh $SSH_OPTS -i $SSH_KEY ${VM_USER[$vm]}@${VM_IP[$vm]} true; echo rc=\$?"
  printf '%s' "$LAST_OUT" | grep -qx "rc=0" \
    && ko "network_spec1" "$vm (${VM_IP[$vm]}) JOIGNABLE en direct (anormal)" \
    || ok "network_spec1" "$vm (${VM_IP[$vm]}) injoignable en direct -> isolé"
done
run "$(ssh_vm netbox-s1 'echo OK via bastion: $(hostname)')"
printf '%s' "$LAST_OUT" | grep -q "OK via bastion" \
  && ok "network_spec1" "VM joignables VIA bastion (isolées, pas en panne)" \
  || ko "network_spec1" "VM injoignables même via bastion"
}

sec3() {
hdr "3. VM - identité & adressage"
for vm in netbox-s1 elastic-s1 web-s2; do
  run "$(ssh_vm "$vm" 'hostname; hostname -I; . /etc/os-release; echo $PRETTY_NAME')"
  printf '%s' "$LAST_OUT" | grep -qw "${VM_IP[$vm]}" \
    && ok "infra_spec" "$vm porte l'IP ${VM_IP[$vm]} ($(printf '%s' "$LAST_OUT" | tail -1))" \
    || ko "infra_spec" "$vm : IP ${VM_IP[$vm]} non trouvée"
done
}

sec4() {
hdr "4. VPN site-à-site (OpenVPN)"
run "$(ssh_vm netbox-s1 "ping -c 2 -W 2 ${VM_IP[web-s2]}")"
printf '%s' "$LAST_OUT" | grep -qE "2 (received|packets received)" \
  && ok "network_vpn" "S1 atteint S2 (web-s2) via le tunnel" || ko "network_vpn" "S1 ne joint pas S2"
run "$(ssh_vm web-s2 "ping -c 2 -W 2 ${VM_IP[netbox-s1]}")"
printf '%s' "$LAST_OUT" | grep -qE "2 (received|packets received)" \
  && ok "network_vpn" "S2 atteint S1 (netbox-s1) via le tunnel" || ko "network_vpn" "S2 ne joint pas S1"
}

sec5() {
hdr "5. DNS forwarding - matrice complète 6 noms × 2 sites"
declare -A EXP=( [netbox-s1.$DOM_S1]=10.10.0.10 [elastic-s1.$DOM_S1]=10.10.0.20 [pf1.$DOM_S1]=10.10.0.1
                 [web-s2.$DOM_S2]=10.20.0.20 [bastion-s2.$DOM_S2]=10.20.0.10 [pf2.$DOM_S2]=10.20.0.1 )
for src in netbox-s1 web-s2; do
  printf "  ${GR}- depuis %s -${X}\n" "$src"
  for fqdn in "${!EXP[@]}"; do
    run "$(ssh_vm "$src" "getent hosts $fqdn")"
    got=$(printf '%s' "$LAST_OUT" | awk '{print $1}' | head -1)
    [ "$got" = "${EXP[$fqdn]}" ] \
      && ok "network_dns" "[$src] $fqdn -> $got" \
      || ko "network_dns" "[$src] $fqdn -> '${got:-vide}' (attendu ${EXP[$fqdn]})"
  done
done
}

sec6() {
hdr "6. IPAM - NetBox déployé ET peuplé"
run "$(ssh_vm netbox-s1 'curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost/')"
printf '%s' "$LAST_OUT" | grep -qE "HTTP (200|302)" \
  && ok "network_ip_mngmt" "NetBox répond ($(printf '%s' "$LAST_OUT" | grep -o 'HTTP [0-9]*'))" \
  || ko "network_ip_mngmt" "NetBox ne répond pas"
local tok; tok="$(get_nb_token)"
if [ -n "$tok" ]; then
  run "$(ssh_vm netbox-s1 "curl -s -H 'Authorization: Token $tok' http://localhost/api/ipam/prefixes/ | head -c 80")"
  local n; n=$(printf '%s' "$LAST_OUT" | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+')
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ok "network_ip_mngmt" "IPAM peuplé : $n préfixe(s) dans NetBox" \
                                  || ko "network_ip_mngmt" "Aucun préfixe dans NetBox (peuplement ?)"
  run "$(ssh_vm netbox-s1 "curl -s -H 'Authorization: Token $tok' http://localhost/api/dcim/devices/ | head -c 80")"
  local d; d=$(printf '%s' "$LAST_OUT" | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+')
  [ "${d:-0}" -gt 0 ] 2>/dev/null && ok "network_ip_mngmt" "IPAM peuplé : $d device(s) dans NetBox" \
                                  || ko "network_ip_mngmt" "Aucun device dans NetBox"
else
  skip "network_ip_mngmt" "token NetBox indisponible (lancer depuis le repo avec vault_password.txt)"
fi
}

sec7() {
hdr "7. Observabilité - logs + métriques centralisés"
# 7a. ES up
run "$(ssh_vm elastic-s1 "curl -s http://${ES_HOST}:${ES_PORT} | head -c 200")"
printf '%s' "$LAST_OUT" | grep -q '"cluster_name"' \
  && ok "log_centralisation" "Elasticsearch UP ($(printf '%s' "$LAST_OUT" | grep -o '"cluster_name"[^,]*' | cut -d'"' -f4))" \
  || ko "log_centralisation" "Elasticsearch ne répond pas"
# 7b. logs des 2 sites
run "$(ssh_vm elastic-s1 "curl -s 'http://${ES_HOST}:${ES_PORT}/_cat/indices?h=index' | grep -E 'filebeat' | sort -u")"
n1=$(printf '%s' "$LAST_OUT" | grep -c "filebeat-site1"); n2=$(printf '%s' "$LAST_OUT" | grep -c "filebeat-site2")
[ "$n1" -gt 0 ] && [ "$n2" -gt 0 ] && ok "log_centralisation" "Logs des 2 sites indexés (s1:$n1 s2:$n2)" \
  || ko "log_centralisation" "Logs incomplets (s1:$n1 s2:$n2)"
# 7c. logs pfSense (firewalls)
run "$(ssh_vm elastic-s1 "curl -s 'http://${ES_HOST}:${ES_PORT}/_cat/indices/pfsense-*?h=index,docs.count'")"
printf '%s' "$LAST_OUT" | grep -q "pfsense" \
  && ok "log_centralisation" "Logs pfSense (firewalls) centralisés dans ES" \
  || ko "log_centralisation" "Index pfsense-* absent (Remote Syslog pfSense configuré ?)"
# 7d. métriques
run "$(ssh_vm elastic-s1 "curl -s 'http://${ES_HOST}:${ES_PORT}/_cat/indices/metricbeat-*?h=index,docs.count'")"
printf '%s' "$LAST_OUT" | grep -q "metricbeat" \
  && ok "log_observability" "Métriques système (Metricbeat) dans ES" \
  || ko "log_observability" "Index metricbeat-* absent (Metricbeat déployé ?)"
# 7e. filebeat actif
fb_ok=0; for vm in netbox-s1 elastic-s1 web-s2; do
  run "$(ssh_vm "$vm" 'systemctl is-active filebeat metricbeat | tr "\n" " "')"
  printf '%s' "$LAST_OUT" | grep -qE "active active" && fb_ok=$((fb_ok+1)); done
[ "$fb_ok" = 3 ] && ok "log_observability" "Filebeat + Metricbeat actifs sur les 3 VM" \
                 || ko "log_observability" "Beats actifs sur $fb_ok/3 VM"
}

sec8() {
hdr "8. Site web interne uniquement"
run "$(ssh_vm web-s2 'curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost/')"
printf '%s' "$LAST_OUT" | grep -q "HTTP 200" \
  && ok "network_spec1" "Site web répond en interne (HTTP 200)" || ko "network_spec1" "Site web ne répond pas"
run "curl -s -o /dev/null -w 'HTTP %{http_code}' --connect-timeout 6 http://${BASTION_HOST}/ 2>&1; echo rc=\$?"
printf '%s' "$LAST_OUT" | grep -q "HTTP 200" \
  && ko "network_spec1" "Une page HTTP répond sur l'IP publique (à vérifier)" \
  || ok "network_spec1" "Aucun site web exposé publiquement"
}

sec9() {
hdr "9. Secrets - vault"
local V="ansible/inventory/group_vars/all/vault.yml"
run "head -1 $REPO_DIR/$V 2>&1"
if printf '%s' "$LAST_OUT" | grep -q '\$ANSIBLE_VAULT'; then ok "sec_credentials" "vault.yml chiffré (ANSIBLE_VAULT)"
elif printf '%s' "$LAST_OUT" | grep -q "No such file"; then skip "sec_credentials" "vault.yml absent ici"
else ko "sec_credentials" "vault.yml NON chiffré"; fi
run "git -C $REPO_DIR check-ignore ansible/vault_password.txt 2>&1; echo rc=\$?"
printf '%s' "$LAST_OUT" | grep -q "vault_password.txt" \
  && ok "sec_credentials" "vault_password.txt ignoré par git" \
  || skip "sec_credentials" "vault_password.txt non suivi/absent"
}

sec10() {
hdr "10. Durcissement bastion - fail2ban / auditd"
if [ "$QUICK" = 1 ]; then skip "sec_bastion" "fail2ban/auditd (--quick)"; return; fi
run "$(ssh_bastion 'systemctl is-active fail2ban auditd | tr "\n" " "')"
printf '%s' "$LAST_OUT" | grep -qE "active active" \
  && ok "sec_bastion" "fail2ban + auditd actifs sur le bastion" \
  || ko "sec_bastion" "fail2ban/auditd non actifs ($(printf '%s' "$LAST_OUT" | tr '\n' ' '))"
}

sec11() {
hdr "11. Firewall - efficacité & séparation des zones"
# Depuis web-s2 (DMZ) : flux LÉGITIMES doivent passer, flux INTERDITS doivent être bloqués.
printf "  ${GR}- flux légitimes (doivent PASSER) -${X}\n"
run "$(ssh_vm web-s2 "timeout 5 bash -c 'echo > /dev/tcp/${ES_HOST}/9200' 2>&1 && echo OPEN || echo BLOCKED")"
printf '%s' "$LAST_OUT" | grep -q OPEN \
  && ok "network_firewall" "DMZ -> Elasticsearch:9200 autorisé (push logs OK)" \
  || ko "network_firewall" "DMZ -> ES:9200 bloqué - casse Filebeat/Metricbeat !"
printf "  ${GR}- flux INTERDITS (doivent être BLOQUÉS) -${X}\n"
run "$(ssh_vm web-s2 "timeout 5 bash -c 'echo > /dev/tcp/${VM_IP[netbox-s1]}/22' 2>&1 && echo OPEN || echo BLOCKED")"
printf '%s' "$LAST_OUT" | grep -q BLOCKED \
  && ok "network_firewall" "DMZ -> SSH(22) services BLOQUÉ (séparation des zones OK)" \
  || ko "network_firewall" "DMZ -> netbox-s1:22 OUVERT - zones NON cloisonnées (à filtrer sur pfSense)"
# Le bastion (admin), lui, DOIT pouvoir SSH partout
run "$(ssh_bastion "timeout 5 bash -c 'echo > /dev/tcp/${VM_IP[netbox-s1]}/22' 2>&1 && echo OPEN || echo BLOCKED")"
printf '%s' "$LAST_OUT" | grep -q OPEN \
  && ok "network_firewall" "Bastion (admin) -> SSH services autorisé (rebond OK)" \
  || ko "network_firewall" "Bastion -> SSH services bloqué - casse l'admin !"
}

sec12() {
hdr "12. Kill switch (coupure d'urgence)"
if [ "$DESTRUCTIVE" != 1 ]; then
  run "ls -l $REPO_DIR/ansible/playbooks/killswitch.yml 2>&1"
  printf '%s' "$LAST_OUT" | grep -q "killswitch.yml" \
    && ok "incident_killswitch" "Playbook killswitch présent (test réel: --destructive)" \
    || skip "incident_killswitch" "killswitch.yml introuvable"
  printf "      ${GR}│ Mode non destructif : ajouter --destructive pour couper/restaurer réellement le VPN${X}\n"
  return
fi
printf "  ${Y}⚠ TEST DESTRUCTIF : coupe le VPN puis le restaure${X}\n"
run "cd $REPO_DIR && make killswitch-cut 2>&1 | tail -3"
sleep 3
run "$(ssh_vm netbox-s1 "ping -c 2 -W 2 ${VM_IP[web-s2]} 2>&1 | tail -2")"
printf '%s' "$LAST_OUT" | grep -qE "100% packet loss|100.0% packet loss" \
  && ok "incident_killswitch" "Kill switch CUT : VPN coupé (S1 ne joint plus S2)" \
  || ko "incident_killswitch" "Kill switch CUT : le VPN répond encore (cut inefficace ?)"
run "cd $REPO_DIR && make killswitch-restore 2>&1 | tail -3"
sleep 5
run "$(ssh_vm netbox-s1 "ping -c 3 -W 2 ${VM_IP[web-s2]} 2>&1 | tail -2")"
printf '%s' "$LAST_OUT" | grep -qE "[123] (received|packets received)" \
  && ok "incident_killswitch" "Kill switch RESTORE : VPN rétabli (recovery OK)" \
  || ko "incident_killswitch" "RESTORE : VPN non rétabli - recovery KO !"
}

sec13() {
hdr "13. IaC - qualité & reproductibilité"
if [ "$QUICK" = 1 ]; then skip "iac_quality" "lint (--quick)"; return; fi
run "cd $REPO_DIR/ansible && ansible-playbook playbooks/site.yml --syntax-check 2>&1 | tail -3"
printf '%s' "$LAST_OUT" | grep -qiE "error|fail" \
  && ko "iac_quality" "syntax-check échoue" || ok "iac_delivery" "Playbook site.yml : syntaxe valide"
run "cd $REPO_DIR/ansible && ansible-lint -c .ansible-lint 2>&1 | tail -4"
printf '%s' "$LAST_OUT" | grep -qiE "Passed|0 failure" \
  && ok "iac_quality" "ansible-lint passe (profile production)" \
  || ko "iac_quality" "ansible-lint signale des problèmes"
}

sec14() {
hdr "14. Documentation & dépôt"
run "ls -1 $REPO_DIR/docs/infra.md $REPO_DIR/docs/pfsense-setup.md $REPO_DIR/docs/runbook.md $REPO_DIR/docs/SCALING.md 2>&1"
[ "$(printf '%s' "$LAST_OUT" | grep -c 'No such file')" = 0 ] \
  && ok "repo_doc" "Documents clés présents (infra, pfSense, runbook, DRP, SCALING)" \
  || ko "repo_doc" "Document(s) manquant(s)"
run "ls -1 2>&1"
printf '%s' "$LAST_OUT" | grep -q runbook && ok "incident_recovery" "DRP présent" || ko "incident_recovery" "DRP manquant"
run "ls -1 $REPO_DIR/docs/diagrams/ 2>&1"
printf '%s' "$LAST_OUT" | grep -qE '\.(json|png|svg|drawio)$' && ok "diagram_delivery" "Diagramme d'infra présent" || ko "diagram_delivery" "Diagramme absent"
run "ls -1 $REPO_DIR/docs/planning/gantt.md $REPO_DIR/docs/planning/backlog.md 2>&1"
[ "$(printf '%s' "$LAST_OUT" | grep -c 'No such file')" = 0 ] \
  && ok "proj_subdivision" "Gantt + backlog versionnés" \
  || skip "proj_subdivision" "Gantt/backlog non versionnés dans docs/planning/"
}

sec15() {
hdr "15. Diagramme, observabilité, dépôt & planning"
# Diagramme : présence des éléments clés + export image
local DIAG; DIAG="$(ls "$REPO_DIR"/docs/diagrams/*.json "$REPO_DIR"/docs/diagrams/*.drawio 2>/dev/null | head -1)"
if [ -n "$DIAG" ]; then
  run "for kw in pfSense VPN Bastion DNS NetBox Elastic site1 site2; do printf '%-10s ' \"\$kw\"; grep -ci \"\$kw\" '$DIAG'; done"
  miss=0; for kw in pfSense VPN Bastion DNS NetBox Elastic site1 site2; do
    grep -qi "$kw" "$DIAG" || { miss=$((miss+1)); printf "      ${GR}│ manquant: %s${X}\n" "$kw"; }; done
  [ "$miss" = 0 ] && ok "diagram_quality" "Diagramme couvre sites/réseaux, VPN, bastion, DNS, IPAM, observabilité" \
                  || ko "diagram_quality" "$miss élément(s) requis absent(s) du diagramme"
  local IMG; IMG="$(ls "$REPO_DIR"/docs/diagrams/*.png "$REPO_DIR"/docs/diagrams/*.pdf "$REPO_DIR"/docs/diagrams/*.svg 2>/dev/null | head -1)"
  [ -n "$IMG" ] \
    && ok "diagram_quality" "Export image présent : $(basename "$IMG")" \
    || ko "diagram_quality" "Aucun export png/pdf/svg du diagramme"
else ko "diagram_quality" "Aucun fichier diagramme (.json/.drawio) dans docs/diagrams/"; fi
# Observabilité : rapport + visuels
run "ls -1 $REPO_DIR/docs/observability/report.html $REPO_DIR/docs/observability/*.svg 2>&1 | head -5"
[ -f "$REPO_DIR/docs/observability/report.html" ] \
  && ok "log_analysis" "Rapport d'analyse télémétrie présent (report.html)" \
  || ko "log_analysis" "report.html absent (lancer 'make observability')"
local nsvg; nsvg=$(ls "$REPO_DIR"/docs/observability/*.svg 2>/dev/null | wc -l)
[ "$nsvg" -gt 0 ] && ok "log_visuals" "$nsvg visualisation(s) SVG versionnée(s)" \
                 || ko "log_visuals" "Aucune visualisation SVG dans docs/observability/"
run "ls -1 $REPO_DIR/scripts/observability.py 2>&1"
printf '%s' "$LAST_OUT" | grep -q observability.py \
  && ok "log_analysis" "Script d'analyse présent (observability.py)" \
  || ko "log_analysis" "observability.py absent"
# Dépôt : gitignore, contributeurs, messages, branches
run "git -C $REPO_DIR ls-files .gitignore | head -1"
printf '%s' "$LAST_OUT" | grep -q gitignore && ok "repo_practices" ".gitignore versionné" || ko "repo_practices" ".gitignore manquant"
run "git -C $REPO_DIR shortlog -sne HEAD | head -6"
local nauth; nauth=$(git -C "$REPO_DIR" shortlog -sne HEAD | grep -c .)
[ "${nauth:-0}" -ge 2 ] && ok "repo_practices" "$nauth contributeurs (travail d'équipe)" \
                        || ko "repo_practices" "Un seul contributeur détecté"
run "git -C $REPO_DIR log --pretty=%s -20 | grep -cE '^(feat|fix|docs|ci|chore|refactor)(\\(|:)'"
local nconv; nconv=$(printf '%s' "$LAST_OUT" | tail -1)
[ "${nconv:-0}" -ge 10 ] && ok "repo_practices" "Messages descriptifs (conventional commits: $nconv/20)" \
                         || ko "repo_practices" "Peu de commits conventionnels ($nconv/20)"
run "git -C $REPO_DIR log --merges --oneline | wc -l"
local nmerge; nmerge=$(printf '%s' "$LAST_OUT" | tail -1)
[ "${nmerge:-0}" -ge 1 ] && ok "repo_practices" "$nmerge merge(s) -> stratégie de branches" \
                         || skip "repo_practices" "Aucun merge (historique linéaire)"
# Contenu du dépôt : code + configs
run "git -C $REPO_DIR ls-files 'ansible/roles/*' 'ansible/inventory/*' | wc -l"
local nfiles; nfiles=$(printf '%s' "$LAST_OUT" | tail -1)
[ "${nfiles:-0}" -gt 10 ] && ok "repo_content" "Configs versionnées : $nfiles fichiers (rôles + inventaire)" \
                          || ko "repo_content" "Peu de configs versionnées ($nfiles)"
# Planning : répartition d'équipe dans le backlog
run "grep -ciE 'Responsable|Yohan|Lena|Lothaire|Nash' $REPO_DIR/docs/planning/backlog.md 2>&1"
local nresp; nresp=$(printf '%s' "$LAST_OUT" | tail -1)
[ "${nresp:-0}" -ge 5 ] && ok "proj_planning" "Backlog avec répartition d'équipe (responsables nommés)" \
                        || ko "proj_planning" "Backlog sans répartition par membre (ajouter colonne Responsable)"
}

# ---------------------------------------------------------------------------
# Catalogue des sections
# ---------------------------------------------------------------------------
declare -A SECTIONS=(
 [0]="Pré-requis locaux"          [1]="Bastion (entrée publique)"
 [2]="Isolation des VM"           [3]="Identité & adressage VM"
 [4]="VPN site-à-site"            [5]="DNS forwarding (matrice)"
 [6]="IPAM NetBox (peuplé)"       [7]="Observabilité (logs+métriques)"
 [8]="Site web interne"           [9]="Secrets (vault)"
 [10]="Durcissement bastion"      [11]="Firewall (zones/efficacité)"
 [12]="Kill switch"               [13]="IaC (lint/reproductibilité)"
 [14]="Documentation & dépôt"     [15]="Diagramme/obs/dépôt/planning"
)
ORDER=(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)

banner() {
printf "${BD}${C}"
cat <<'BANNER'
   ____ ___    _      __     __    _ _     _       _   _
  / ___|_ _|  / \     \ \   / /_ _| (_) __| | __ _| |_(_) ___  _ __
 | |    | |  / _ \     \ \ / / _` | | |/ _` |/ _` | __| |/ _ \| '_ \
 | |___ | | / ___ \     \ V / (_| | | | (_| | (_| | |_| | (_) | | | |
  \____|___/_/   \_\     \_/ \__,_|_|_|\__,_|\__,_|\__|_|\___/|_| |_|
BANNER
printf "${X}${GR}  Validation de l'infrastructure${X}\n"
printf "${GR}  %s${X}\n" "$(date '+%Y-%m-%d %H:%M' 2>/dev/null || echo '')"
}

run_sections() {
  for n in "$@"; do "sec$n"; done
  TOTAL=$((PASS+FAIL))
  printf "\n${BD}${B}══════════════════════════ RÉCAPITULATIF ══════════════════════════${X}\n"
  printf "  ${G}%d réussis${X}   ${R}%d échecs${X}   ${Y}%d ignorés${X}   (sur %d tests)\n" "$PASS" "$FAIL" "$SKIP" "$TOTAL"
  if [ "$FAIL" -gt 0 ]; then printf "\n${R}${BD}  Échecs :${X}\n"
    for t in "${FAILED_TESTS[@]}"; do printf "    ${R}•${X} %s\n" "$t"; done; fi
  if [ "$TOTAL" -gt 0 ]; then
    pct=$(( PASS * 100 / TOTAL )); filled=$(( pct * 40 / 100 ))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((40-filled)) '' | tr ' ' '.')
    col=$G; [ "$pct" -lt 100 ] && col=$Y; [ "$pct" -lt 70 ] && col=$R
    printf "\n  ${col}[%s] %d%%${X}\n\n" "$bar" "$pct"
  fi
  [ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Menu interactif
# ---------------------------------------------------------------------------
menu() {
  banner
  printf "\n${BD}Sélection des tests${X} ${GR}(ex: 4 5 7, 'all', 'q')${X}\n\n"
  for n in "${ORDER[@]}"; do printf "  ${C}%2d${X}  %s\n" "$n" "${SECTIONS[$n]}"; done
  printf "\n  ${C}all${X}  Tout exécuter      ${C}q${X}  Quitter\n"
  printf "\n${BD}Options actives :${X} quick=%d destructive=%d raw=%d\n" "$QUICK" "$DESTRUCTIVE" "$RAW"
  printf "${GR}(toggle: 'quick', 'destructive', 'raw')${X}\n"
  printf "\n${BD}> ${X}"; read -r answer
  case "$answer" in
    q|quit|exit) exit 0 ;;
    all) clear 2>/dev/null||true; run_sections "${ORDER[@]}"; exit $? ;;
    quick) QUICK=$((1-QUICK)); menu ;;
    destructive) DESTRUCTIVE=$((1-DESTRUCTIVE)); menu ;;
    raw) RAW=$((1-RAW)); menu ;;
    "") menu ;;
    *) clear 2>/dev/null||true
       # garde uniquement les numéros valides
       chosen=(); for x in $answer; do [ -n "${SECTIONS[$x]:-}" ] && chosen+=("$x"); done
       [ ${#chosen[@]} -eq 0 ] && { printf "${R}Sélection invalide${X}\n"; menu; }
       run_sections "${chosen[@]}"; exit $? ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
if [ "$RUN_ALL" = 1 ]; then banner; run_sections "${ORDER[@]}"; exit $?
elif [ ${#SELECTED[@]} -gt 0 ]; then banner; run_sections "${SELECTED[@]}"; exit $?
else menu; fi
