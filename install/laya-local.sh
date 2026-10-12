#!/usr/bin/env bash
#
# laya-local Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      laya-local – lokale Typed-Decision-Engine (choice/score/noul) mit Web-UI
# Upstream: https://github.com/NandhaKishorM/laya (PyTorch-CPU, laeuft auf x86_64)
# Hinweis:  laya-mlx (https://github.com/mizorewww/laya-mlx) laeuft NICHT auf
#           Proxmox – es braucht Apple Silicon + macOS + Metal. Darum nutzt
#           dieser Installer den funktional gleichen PyTorch-Upstream.
# Stack:    Python/FastAPI + Uvicorn (:8080), venv /opt/laya-local/.venv,
#           ohne Docker, ohne Cloud (nur Erst-Download ab HuggingFace).
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LayaJev-Proxmox/main/install/laya-local.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LayaJev-Proxmox/main/install/laya-local.sh)"
#   bash laya-local.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="laya-local"                              # Container-Hostname + Service-Name
APP_PORT="8080"                               # Web-UI + API
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/LayaJev-Proxmox}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/LayaJev-Proxmox/main}"
SERVICE_URL="${SERVICE_URL:-$RAW_BASE/systemd/laya-local.service}"
APP_SERVER_URL="${APP_SERVER_URL:-$RAW_BASE/app/server.py}"
APP_INDEX_URL="${APP_INDEX_URL:-$RAW_BASE/app/static/index.html}"
APP_REQ_URL="${APP_REQ_URL:-$RAW_BASE/app/requirements.txt}"

DEFAULT_CORES="2"                             # vCPU (torch-CPU braucht 2, 4 bei Batch-Last)
DEFAULT_RAM="4096"                            # RAM in MB (421M FP32 ~1.6GB + Overhead, kein OOM)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="12"                             # Disk in GB (OS + torch ~4-5GB + Modelle 1-3GB)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie
UNPRIVILEGED="1"                              # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                          # nesting fuer pip/venv Robustheit

APP_USER="laya"
APP_DIR="/opt/laya-local"
VENV_DIR="/opt/laya-local/.venv"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=12 ./laya-local.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash laya-local.sh [OPTIONEN]
  CT_ID=150 bash laya-local.sh
  bash -c "\$(wget -qLO - ${RAW_BASE}/install/laya-local.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. laya-local im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere laya-local im Container (nativ, ohne Docker) ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping noetig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3 python3-venv python3-pip
  id laya >/dev/null 2>&1 || useradd -m -s /bin/bash laya
  mkdir -p /opt/laya-local/app/static
  touch /opt/laya-local/app/__init__.py
  chown -R laya:laya /opt/laya-local
'
# Hinweis: bewusst kein "| tail" hier – mit pipefail wuerde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# App-Dateien: erst aus Repo laden, Fallback auf Inline-Dateien.
msg_info "Uebernehme App-Code ..."
if pct exec "$CT_ID" -- curl -fsSL -o /opt/laya-local/app/server.py "$APP_SERVER_URL" 2>/dev/null \
  && pct exec "$CT_ID" -- curl -fsSL -o /opt/laya-local/app/static/index.html "$APP_INDEX_URL" 2>/dev/null \
  && pct exec "$CT_ID" -- curl -fsSL -o /opt/laya-local/requirements.txt "$APP_REQ_URL" 2>/dev/null; then
  msg_ok "App-Code aus Repo uebernommen."
else
  msg_warn "Repo-URLs nicht erreichbar – schreibe Inline-App (Repo-URL oben pruefen)."
  pct push "$CT_ID" /dev/stdin /opt/laya-local/requirements.txt <<'REQ'
laya[serve]>=0.4.1
fastapi>=0.110.0
uvicorn>=0.27.0
REQ
  pct push "$CT_ID" /dev/stdin /opt/laya-local/app/server.py <<'PYEOF'
"""laya-local: lokale FastAPI-Huelle um Upstream-laya (CPU, lazy Router)."""
from __future__ import annotations
import threading
from pathlib import Path
from typing import Any
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
app = FastAPI(title="laya-local")
_router = None
_lock = threading.Lock()
def get_router():
    global _router
    if _router is None:
        with _lock:
            if _router is None:
                from laya import Router
                _router = Router()
    return _router
class PredictIn(BaseModel):
    state: Any
    questions: dict[str, Any]
    model: str | None = None
    lang: str | None = None
@app.get("/health")
def health():
    return {"status": "ok"}
@app.post("/api/predict")
def predict(body: PredictIn):
    try:
        router = get_router()
        kwargs: dict[str, Any] = {}
        if body.model:
            kwargs["model"] = body.model
        if body.lang:
            kwargs["lang"] = body.lang
        return router.predict(body.state, body.questions, **kwargs)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"{type(exc).__name__}: {exc}") from exc
STATIC = Path(__file__).parent / "static"
@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")
def main():
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
PYEOF
  pct push "$CT_ID" /dev/stdin /opt/laya-local/app/static/index.html <<'HTMLEOF'
<!doctype html><html lang="de"><head><meta charset="utf-8"><title>laya-local</title></head><body>
<h1>laya-local (Proxmox LXC)</h1>
<p>Lokale Typed-Decision-Engine. Erster Aufruf lädt Checkpoint (30-90s).</p>
<textarea id="state" rows="4" cols="60">We were billed twice. Please refund the duplicate.</textarea><br>
<button id="go">Entscheiden</button>
<pre id="out">Bereit.</pre>
<script>
document.getElementById("go").onclick = async () => {
  document.getElementById("out").textContent = "lädt … (Erstaufruf 30-90s)";
  const r = await fetch("/api/predict", {method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({state: document.getElementById("state").value,
      questions: {department: {type: "choice", instructions: "Which team?",
        criteria: {billing: "refunds", technical: "bugs", sales: "new contracts"}}}})});
  document.getElementById("out").textContent = await r.text();
};
</script></body></html>
HTMLEOF
fi
pct exec "$CT_ID" -- chown -R laya:laya /opt/laya-local

# venv + Deps (idempotent, dauert beim ersten Mal mehrere Minuten wegen torch-CPU)
msg_info "Installiere Python-Deps im Container (torch-CPU, dauert Minuten) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  if [ ! -x /opt/laya-local/.venv/bin/python ]; then
    python3 -m venv /opt/laya-local/.venv
  fi
  /opt/laya-local/.venv/bin/pip install --upgrade pip
  # CPU-only torch VOR laya: das Default-torch-Rad zieht sonst den kompletten
  # CUDA-Ballast (nvidia-*-Pakete, mehrere GB) und sprengt kleine Disks mit
  # Errno 28. --no-cache-dir halbiert den Spitzenverbrauch zusaetzlich.
  /opt/laya-local/.venv/bin/pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
  /opt/laya-local/.venv/bin/pip install --no-cache-dir -r /opt/laya-local/requirements.txt
  /opt/laya-local/.venv/bin/python -c "import fastapi, uvicorn; print(fastapi.__version__)"
  chown -R laya:laya /opt/laya-local
'

# Host-seitiger Guard: bricht laut ab, falls der App-Code fehlt.
pct exec "$CT_ID" -- test -f /opt/laya-local/app/server.py \
  || { msg_error "App-Code unvollstaendig: /opt/laya-local/app/server.py fehlt im Container."; exit 1; }
msg_ok "App-Code ok (server.py vorhanden)."

# systemd-Unit aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/laya-local.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "laya-local.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/laya-local.service <<UNIT
[Unit]
Description=laya-local – lokale Typed-Decision-Engine mit Web-UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=laya
Group=laya
WorkingDirectory=/opt/laya-local
Environment=PYTHONUNBUFFERED=1
Environment=OMP_NUM_THREADS=4
ExecStart=/opt/laya-local/.venv/bin/python -m uvicorn app.server:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now laya-local

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active laya-local || { msg_error "systemd-Service laya-local ist nicht active."; pct exec "$CT_ID" -- systemctl status laya-local --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active laya-local = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/health" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/health."; pct exec "$CT_ID" -- systemctl status laya-local --no-pager || true; pct exec "$CT_ID" -- journalctl -u laya-local --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/health)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : laya-local – lokale Typed-Decision-Engine mit Web-UI"
echo "  Upstream     : https://github.com/NandhaKishorM/laya"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  API          : http://${CT_IP}:${APP_PORT}/api/predict (POST state+questions)"
echo "  Health       : http://${CT_IP}:${APP_PORT}/health"
echo "  Hinweis      : Erster Predict laedt Checkpoint (30-90s, einmalig Netz zu HuggingFace)."
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status laya-local  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/health"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
