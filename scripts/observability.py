#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Analyse de la télémétrie centralisée (Elasticsearch) via les aggregations
natives d'ES, et génération de visualisations SVG. Chaque requête est affichée
avant d'être envoyée.

Elasticsearch (10.10.0.20:9200) n'étant pas exposé, le script ouvre un tunnel
SSH via le bastion puis interroge ES en local.

Sorties : docs/observability/report.html + docs/observability/*.svg

Usage :
  python3 scripts/observability.py             # tunnel auto via bastion
  python3 scripts/observability.py --es URL    # ES déjà joignable
  python3 scripts/observability.py --days 7    # fenêtre d'analyse (défaut 7 j)
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

# --- Constantes infra (cohérentes avec ansible/inventory) ---------------------
BASTION = ("bastion", "5.135.202.79", 2222)
SSH_KEY = os.path.expanduser("~/.ssh/cia_ansible")
ES_INTERNAL = ("10.10.0.20", 9200)
LOCAL_PORT = 19200
INDEX = "filebeat-*"
OUTDIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "docs", "observability")

# --- Couleurs console ---------------------------------------------------------
C = dict(c="\033[36m", g="\033[32m", y="\033[33m", r="\033[31m",
         gr="\033[90m", b="\033[1m", x="\033[0m")
if not sys.stdout.isatty():
    C = {k: "" for k in C}


def show_query(title, method, path, body):
    """Affiche la requête ES EXACTE (reproductible en curl) avant exécution."""
    print(f"\n{C['b']}{C['c']}▶ {title}{C['x']}")
    url = f"http://{ES_INTERNAL[0]}:{ES_INTERNAL[1]}/{path}"
    if body is None:
        print(f"  {C['gr']}# Équivalent curl (à rejouer depuis une VM du site 1) :{C['x']}")
        print(f"  {C['c']}curl -s '{url}'{C['x']}")
    else:
        pretty = json.dumps(body, ensure_ascii=False)
        print(f"  {C['gr']}# Équivalent curl (à rejouer depuis une VM du site 1) :{C['x']}")
        print(f"  {C['c']}curl -s '{url}' -H 'Content-Type: application/json' -d '{pretty}'{C['x']}")


def es(sess_base, path, body=None):
    """Envoie la requête à ES (via le tunnel local) et renvoie le JSON."""
    url = f"{sess_base}/{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method="POST" if data else "GET",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


# --- Tunnel SSH ---------------------------------------------------------------
def open_tunnel():
    """Ouvre ssh -L vers ES via le bastion. Affiche la commande (transparence)."""
    user, host, port = BASTION
    cmd = ["ssh", "-i", SSH_KEY, "-p", str(port), "-N",
           "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=no",
           "-L", f"{LOCAL_PORT}:{ES_INTERNAL[0]}:{ES_INTERNAL[1]}",
           f"{user}@{host}"]
    print(f"{C['gr']}# Ouverture d'un tunnel SSH vers Elasticsearch via le bastion :{C['x']}")
    print(f"  {C['c']}{' '.join(cmd)}{C['x']}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{LOCAL_PORT}"
    for _ in range(20):
        time.sleep(0.5)
        try:
            urllib.request.urlopen(base, timeout=2)
            print(f"  {C['g']}✔ tunnel établi ({base} -> {ES_INTERNAL[0]}:{ES_INTERNAL[1]}){C['x']}\n")
            return proc, base
        except Exception:
            continue
    proc.terminate()
    sys.exit(f"{C['r']}Tunnel SSH impossible. Vérifier la clé {SSH_KEY} et l'accès au bastion.{C['x']}")


# --- Rendu SVG (zéro dépendance) ----------------------------------------------
def svg_bars(title, pairs, fname, color="#2563eb"):
    """Génère un graphe en barres horizontales en SVG pur."""
    pairs = pairs[:12]
    if not pairs:
        pairs = [("(aucune donnée)", 0)]
    w, bar_h, gap, label_w, top = 720, 26, 10, 230, 50
    h = top + len(pairs) * (bar_h + gap) + 20
    mx = max((v for _, v in pairs), default=1) or 1
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="monospace">']
    out.append(f'<text x="16" y="28" font-size="17" font-weight="bold">{esc(title)}</text>')
    y = top
    for label, val in pairs:
        bw = int((w - label_w - 90) * val / mx)
        out.append(f'<text x="16" y="{y+bar_h-8}" font-size="13">{esc(str(label))[:32]}</text>')
        out.append(f'<rect x="{label_w}" y="{y}" width="{max(bw,1)}" height="{bar_h}" fill="{color}" rx="3"/>')
        out.append(f'<text x="{label_w+bw+8}" y="{y+bar_h-8}" font-size="13" fill="#333">{val}</text>')
        y += bar_h + gap
    out.append("</svg>")
    svg = "\n".join(out)
    with open(os.path.join(OUTDIR, fname), "w") as f:
        f.write(svg)
    return svg


def svg_timeline(title, points, fname, color="#16a34a"):
    """Génère une courbe temporelle (volumétrie) en SVG pur."""
    if not points:
        points = [("n/a", 0)]
    w, h, pad = 720, 240, 50
    mx = max((v for _, v in points), default=1) or 1
    n = len(points)
    step = (w - 2 * pad) / max(n - 1, 1)
    pts = []
    for i, (_, v) in enumerate(points):
        x = pad + i * step
        yv = h - pad - (h - 2 * pad) * v / mx
        pts.append(f"{x:.0f},{yv:.0f}")
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="monospace">']
    out.append(f'<text x="16" y="26" font-size="17" font-weight="bold">{esc(title)}</text>')
    out.append(f'<line x1="{pad}" y1="{h-pad}" x2="{w-pad}" y2="{h-pad}" stroke="#ccc"/>')
    out.append(f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{" ".join(pts)}"/>')
    # étiquettes début/milieu/fin
    for idx in {0, n // 2, n - 1}:
        if 0 <= idx < n:
            x = pad + idx * step
            out.append(f'<text x="{x:.0f}" y="{h-pad+18}" font-size="11" text-anchor="middle" fill="#666">{esc(str(points[idx][0]))}</text>')
    out.append(f'<text x="{w-pad}" y="{pad-10}" font-size="11" fill="#666" text-anchor="end">max={mx}</text>')
    out.append("</svg>")
    svg = "\n".join(out)
    with open(os.path.join(OUTDIR, fname), "w") as f:
        f.write(svg)
    return svg


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def show_result(buckets, key="key", count="doc_count"):
    """Affiche la réponse ES (transparence)."""
    if not buckets:
        print(f"  {C['y']}│ (aucun bucket){C['x']}")
        return
    for b in buckets[:10]:
        print(f"  {C['gr']}│{C['x']} {b[key]}: {C['b']}{b[count]}{C['x']}")


# --- Programme principal ------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Analyse télémétrie ES (transparente)")
    ap.add_argument("--es", help="URL ES déjà joignable (sinon tunnel via bastion)")
    ap.add_argument("--days", type=int, default=7, help="fenêtre d'analyse (jours)")
    args = ap.parse_args()

    os.makedirs(OUTDIR, exist_ok=True)
    print(f"{C['b']}{C['c']}=== Analyse de la télémétrie centralisée (Elasticsearch) ==={C['x']}")
    print(f"{C['gr']}Index analysé : {INDEX}, fenêtre : {args.days} j.{C['x']}\n")

    proc = None
    if args.es:
        base = args.es.rstrip("/")
        print(f"{C['gr']}ES fourni : {base}{C['x']}\n")
    else:
        proc, base = open_tunnel()

    rng = {"range": {"@timestamp": {"gte": f"now-{args.days}d"}}}
    cards = []  # (titre, svg) pour le rapport HTML

    try:
        # 1. Santé du cluster ---------------------------------------------------
        show_query("Santé du cluster Elasticsearch", "GET", "_cluster/health", None)
        h = es(base, "_cluster/health")
        print(f"  {C['gr']}│{C['x']} status={C['b']}{h['status']}{C['x']} "
              f"nodes={h['number_of_nodes']} shards={h['active_shards']}")

        # 2. Volumétrie totale + par site --------------------------------------
        body = {"size": 0, "track_total_hits": True, "query": rng,
                "aggs": {"sites": {"terms": {"field": "site"}}}}
        show_query("Volume de logs par site (aggregation terms)", "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        total = r["hits"]["total"]["value"]
        sb = r["aggregations"]["sites"]["buckets"]
        print(f"  {C['gr']}│{C['x']} total logs (fenêtre) = {C['b']}{total}{C['x']}")
        show_result(sb)
        cards.append(("Logs par site", svg_bars("Logs par site",
                     [(b["key"], b["doc_count"]) for b in sb], "logs_par_site.svg")))

        # 3. Par hôte -----------------------------------------------------------
        body = {"size": 0, "query": rng,
                "aggs": {"hosts": {"terms": {"field": "host.name", "size": 10}}}}
        show_query("Logs par hôte (qui génère quoi)", "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        hb = r["aggregations"]["hosts"]["buckets"]
        show_result(hb)
        cards.append(("Logs par hôte", svg_bars("Logs par hôte",
                     [(b["key"], b["doc_count"]) for b in hb], "logs_par_hote.svg",
                     color="#7c3aed")))

        # 4. Par fichier source (auth, syslog, nginx, fail2ban) -----------------
        body = {"size": 0, "query": rng,
                "aggs": {"paths": {"terms": {"field": "log.file.path", "size": 10}}}}
        show_query("Logs par fichier source", "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        pb = [{"key": b["key"].split("/")[-1], "doc_count": b["doc_count"]}
              for b in r["aggregations"]["paths"]["buckets"]]
        show_result(pb)
        cards.append(("Logs par fichier source", svg_bars("Logs par fichier source",
                     [(b["key"], b["doc_count"]) for b in pb], "logs_par_fichier.svg",
                     color="#ea580c")))

        # 5. SÉCURITÉ : tentatives SSH échouées (analyse auth.log) --------------
        body = {"size": 0, "track_total_hits": True,
                "query": {"bool": {"must": [rng,
                          {"match_phrase": {"message": "Failed password"}}]}},
                "aggs": {"hosts": {"terms": {"field": "host.name", "size": 10}}}}
        show_query("Sécurité - tentatives SSH échouées ('Failed password') par hôte",
                   "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        fails = r["hits"]["total"]["value"]
        fb = r["aggregations"]["hosts"]["buckets"]
        print(f"  {C['gr']}│{C['x']} total tentatives échouées : {C['b']}{fails}{C['x']}")
        show_result(fb)
        cards.append((f"Tentatives SSH échouées par hôte (total {fails})",
                     svg_bars("SSH 'Failed password' par hôte",
                     [(b["key"], b["doc_count"]) for b in fb], "ssh_failed.svg",
                     color="#dc2626")))

        # 6. SÉCURITÉ : top IP sources des attaques SSH (extraites du message) --
        # On agrège sur le mot suivant "from " dans les lignes "Failed password".
        # Champ message non-keyword -> on récupère un échantillon et on compte côté client.
        body = {"size": 200, "_source": ["message"],
                "query": {"bool": {"must": [rng,
                          {"match_phrase": {"message": "Failed password"}}]}}}
        show_query("Sécurité - IP sources des tentatives SSH échouées (top attaquants)",
                   "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        ip_count = {}
        import re as _re
        for hit in r["hits"]["hits"]:
            m = _re.search(r"from (\d{1,3}(?:\.\d{1,3}){3})", hit["_source"].get("message", ""))
            if m:
                ip_count[m.group(1)] = ip_count.get(m.group(1), 0) + 1
        top_ip = sorted(ip_count.items(), key=lambda kv: -kv[1])[:10]
        print(f"  {C['gr']}│{C['x']} {len(ip_count)} IP distinctes détectées (échantillon {len(r['hits']['hits'])} events)")
        show_result([{"key": k, "doc_count": v} for k, v in top_ip])
        cards.append(("Top IP sources des tentatives SSH échouées",
                     svg_bars("Top IP attaquantes (SSH)", top_ip, "ssh_top_ip.svg",
                     color="#dc2626")))

        # 7. Volumétrie globale dans le temps ----------------------------------
        body = {"size": 0, "query": rng,
                "aggs": {"t": {"date_histogram":
                          {"field": "@timestamp", "calendar_interval": "day"}}}}
        show_query("Volumétrie de logs dans le temps (tous composants)",
                   "POST", f"{INDEX}/_search", body)
        r = es(base, f"{INDEX}/_search", body)
        tb = r["aggregations"]["t"]["buckets"]
        tpts = [(b["key_as_string"][5:10], b["doc_count"]) for b in tb]
        show_result([{"key": k, "doc_count": v} for k, v in tpts])
        cards.append(("Volumétrie de logs / jour (tous composants)",
                     svg_timeline("Volumétrie de logs / jour", tpts,
                     "volumetrie.svg", color="#2563eb")))

        # 7b. FIREWALL : paquets bloqués par les pfSense (index pfsense-*) ------
        body = {"size": 100, "track_total_hits": True, "_source": ["message"],
                "query": {"bool": {"must": [{"match": {"message": "block"}}]}}}
        show_query("Firewall - IP sources bloquées par les pfSense (filterlog)",
                   "POST", "pfsense-*/_search", body)
        try:
            r = es(base, "pfsense-*/_search", body)
            blocked = r["hits"]["total"]["value"]
            import re as _re2
            bip = {}
            for hit in r["hits"]["hits"]:
                m = _re2.findall(r"\d{1,3}(?:\.\d{1,3}){3}", hit["_source"].get("message", ""))
                if m:
                    bip[m[0]] = bip.get(m[0], 0) + 1
            top_b = sorted(bip.items(), key=lambda kv: -kv[1])[:10]
            print(f"  {C['gr']}│{C['x']} total paquets bloqués : {C['b']}{blocked}{C['x']}")
            show_result([{"key": k, "doc_count": v} for k, v in top_b])
            cards.append((f"IP sources bloquées par les pfSense (≈{blocked} blocages)",
                         svg_bars("IP bloquées par le firewall", top_b,
                         "firewall_blocked.svg", color="#b91c1c")))
        except Exception as e:
            print(f"  {C['y']}│ index pfsense-* indisponible ({e}) - Remote Syslog pfSense configuré ?{C['x']}")

        # 8. MÉTRIQUES système (Metricbeat) - mémoire moyenne par hôte ----------
        body = {"size": 0, "query": rng,
                "aggs": {"hosts": {"terms": {"field": "host.name", "size": 6},
                          "aggs": {"mem": {"avg": {"field": "system.memory.used.pct"}}}}}}
        show_query("Métriques système - mémoire moyenne utilisée par hôte (Metricbeat)",
                   "POST", "metricbeat-*/_search", body)
        try:
            r = es(base, "metricbeat-*/_search", body)
            mb = r["aggregations"]["hosts"]["buckets"]
            mem_pairs = [(b["key"], round((b["mem"]["value"] or 0) * 100, 1)) for b in mb]
            show_result([{"key": k, "doc_count": f"{v}%"} for k, v in mem_pairs])
            cards.append(("Mémoire moyenne par hôte (%)",
                         svg_bars("Mémoire utilisée moyenne (%)", mem_pairs,
                         "metrics_memoire.svg", color="#0891b2")))
        except Exception as e:
            print(f"  {C['y']}│ métriques indisponibles ({e}) - Metricbeat déployé ?{C['x']}")

        # 9. MÉTRIQUES - charge CPU moyenne par hôte ---------------------------
        body = {"size": 0, "query": rng,
                "aggs": {"hosts": {"terms": {"field": "host.name", "size": 6},
                          "aggs": {"cpu": {"avg": {"field": "system.cpu.total.pct"}}}}}}
        show_query("Métriques système - charge CPU moyenne par hôte (Metricbeat)",
                   "POST", "metricbeat-*/_search", body)
        try:
            r = es(base, "metricbeat-*/_search", body)
            cb = r["aggregations"]["hosts"]["buckets"]
            cpu_pairs = [(b["key"], round((b["cpu"]["value"] or 0) * 100, 1)) for b in cb]
            show_result([{"key": k, "doc_count": f"{v}%"} for k, v in cpu_pairs])
            cards.append(("Charge CPU moyenne par hôte (%)",
                         svg_bars("CPU utilisé moyen (%)", cpu_pairs,
                         "metrics_cpu.svg", color="#0891b2")))
        except Exception as e:
            print(f"  {C['y']}│ métriques CPU indisponibles ({e}){C['x']}")

    finally:
        if proc:
            proc.terminate()

    # --- Rapport HTML ---------------------------------------------------------
    html = ["<!doctype html><html lang='fr'><head><meta charset='utf-8'>",
            "<title>CIA - Observabilité (Elasticsearch)</title>",
            "<style>body{font-family:system-ui,sans-serif;max-width:840px;margin:24px auto;"
            "padding:0 16px;color:#1f2937}h1{color:#1e3a8a}.card{border:1px solid #e5e7eb;"
            "border-radius:10px;padding:14px 18px;margin:18px 0;box-shadow:0 1px 3px #0001}"
            ".meta{color:#6b7280;font-size:14px}code{background:#f3f4f6;padding:1px 5px;"
            "border-radius:4px}</style></head><body>",
            "<h1>CIA - Analyse de la télémétrie centralisée</h1>",
            "<p class='meta'>Source : Elasticsearch (cluster <code>cia-logging</code>). "
            "Données : <b>logs</b> (Filebeat, index <code>filebeat-*</code> / "
            "<code>pfsense-*</code>) et <b>métriques système</b> (Metricbeat, index "
            "<code>metricbeat-*</code>) des deux sites. "
            "Analyse réalisée via les <b>aggregations natives d'Elasticsearch</b> "
            "(pas de Kibana/Grafana - contrainte 2 Gio/VM). "
            "Chaque graphe correspond à une requête ES affichée par "
            "<code>scripts/observability.py</code>.</p>"]
    for title, svg in cards:
        html.append(f"<div class='card'><h3>{esc(title)}</h3>{svg}</div>")
    html.append("</body></html>")
    report = os.path.join(OUTDIR, "report.html")
    with open(report, "w") as f:
        f.write("\n".join(html))

    print(f"\n{C['b']}{C['g']}✔ Rapport généré : {report}{C['x']}")
    print(f"{C['gr']}  Graphes SVG individuels dans {OUTDIR}/{C['x']}")
    print(f"{C['gr']}  Ouvre report.html dans un navigateur pour la vue d'ensemble.{C['x']}")


if __name__ == "__main__":
    main()
