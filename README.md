# laya-local auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App: `https://github.com/NandhaKishorM/laya` (PyTorch, läuft auf x86_64-CPU)
> Hinweis: `laya-mlx` (`https://github.com/mizorewww/laya-mlx`) läuft **nicht** auf Proxmox – es braucht Apple Silicon + macOS + Metal. Dieser Installer nutzt den funktional gleichen PyTorch-Upstream (gleiche Gewichte, gleiche `choice`/`score`/`noul`-Antworten, nur 200–500ms statt 7–13ms).
> Dieser Ordner enthält App-Code (`app/`), Installer (`install/`) und systemd-Unit (`systemd/`).

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LayaJev-Proxmox/main/install/laya-local.sh)"
```

> Per Env-Override auf ein anderes Repo zeigen (ohne Script zu ändern):
> ```bash
> RAW_BASE=https://raw.githubusercontent.com/DEIN/REPO/main bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN/REPO/main/install/laya-local.sh)"
> ```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LayaJev-Proxmox/main/install/laya-local.sh)"
bash laya-local.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --bridge vmbr0 --storage local-lvm
bash laya-local.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/laya-local-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `laya-local` |
| Zweck | Lokale Typed-Decision-Engine (`choice`/`score`/`noul`) mit Web-UI, 100% lokal nach Erst-Download |
| Tech-Stack | Python/FastAPI + Uvicorn (`:8080`), `laya[serve]` (torch-CPU), venv `/opt/laya-local/.venv` |
| GitHub-Repo (Upstream) | `https://github.com/NandhaKishorM/laya` |
| Web UI | `http://<LXC-IP>:8080` (Formular + Triage-Preset), Health `/health`, API `POST /api/predict` |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 12 GB Disk (Minimum für torch 421M ohne OOM; 4/8GB/20GB bei Batch-Last) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `laya-local` (`onboot: 1`, unprivilegiert),
3. installiert im Container Python+venv+git, legt User `laya` an, übernimmt App-Code aus diesem Repo (Fallback: Inline-App im Script), installiert `requirements.txt` (`laya[serve]` + FastAPI + Uvicorn), schreibt `laya-local.service`, `systemctl enable --now laya-local`,
4. verifiziert `systemctl is-active laya-local` + HTTP auf `localhost:8080/health` und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active laya-local = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8080/health).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : laya-local – lokale Typed-Decision-Engine mit Web-UI
  Container    : CT 100 (Hostname: laya-local, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 12 GB Disk
  Web UI       : http://192.168.1.100:8080
  API          : http://192.168.1.100:8080/api/predict (POST state+questions)
  Health       : http://192.168.1.100:8080/health
  Hinweis      : Erster Predict lädt Checkpoint (30-90s, einmalig Netz zu HuggingFace).
  ...
  Log          : /tmp/laya-local-install-2026-....log
══════════════════════════════════════════════════════════
```

API-Test (nachdem Health OK ist; Erstaufruf 30–90s):

```bash
curl -s http://<LXC-IP>:8080/api/predict -H 'content-type: application/json' -d '{
  "state": "We were billed twice. Please refund the duplicate.",
  "questions": {"department": {"type": "choice", "instructions": "Which team?",
    "criteria": {"billing": "refunds", "technical": "bugs", "sales": "new contracts"}}}
}' | python3 -m json.tool
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active laya-local
curl -fs http://<LXC-IP>:8080/health >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash laya-local.sh --ctid 100            # Update: idempotent (Code-Refresh + pip upgrade + restart)
pct stop 100 && pct destroy 100     # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/laya-local-install-*.log`.
- `bash laya-local.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status laya-local --no-pager`, `journalctl -u laya-local -n 100`.

## Dateien

- `install/laya-local.sh` – Proxmox-Einzeiler (Host, root).
- `app/server.py` – FastAPI-Hülle (lazy `Router`, `GET /`, `GET /health`, `POST /api/predict`).
- `app/static/index.html` – Web-UI (Triage-Preset, DE/EN-Beispiel, Ladezustand für Erst-Download).
- `app/requirements.txt` – `laya[serve] + fastapi + uvicorn`.
- `systemd/laya-local.service` – Unit (`:8080`, `After=network-online.target`, `Restart=always`).
