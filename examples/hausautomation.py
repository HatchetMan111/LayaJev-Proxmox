#!/usr/bin/env python3
"""Hausautomation mit laya-local – Sprach-/Textbefehl -> Schaltentscheidung.

Nur Standardbibliothek, keine weiteren Deps. Der LXC mit laya-local muss laufen:

    export LAYA_URL="http://<LXC-IP>:8080/api/predict"
    python3 hausautomation.py "Mach das Licht im Wohnzimmer aus"

Regeln (fail-safe):
  * sicherheitsrelevant (Schloss/Alarm/Garage/Kamera) -> IMMER Rueckfrage,
    egal wie hoch die Confidence ist. Es wird nie direkt geschaltet.
  * confidence < --min-conf (Default 0.8) oder Raum "unklar" -> Rueckfrage.
  * Erstaufruf nach LXC-Reboot dauert 30-90s (Checkpoint-Load) -> Timeout 120s.

Exit-Codes: 0 = schalten (Hook aufgerufen), 2 = Rueckfrage noetig,
1 = Fehler (voller Stacktrace auf stderr, nie nur die letzte Zeile).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
import urllib.request
from pathlib import Path

DEFAULT_QUESTIONS = Path(__file__).parent / "fragen.json"


def laya_predict(url: str, state: str, questions: dict) -> dict:
    body = json.dumps({"state": state, "questions": questions}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def schalten(intent: str, raum: str) -> None:
    """HIER eigenen Hook einhaengen (Home Assistant, MQTT, Shelly, ...).

    Beispiel Home Assistant:
        requests.post(f"{HA_URL}/api/services/light/turn_{on_off}",
                      json={"entity_id": f"light.{raum}"},
                      headers={"Authorization": f"Bearer {HA_TOKEN}"})
    """
    print(f"AKTION: schalte intent={intent} raum={raum}")
    print("(Demo-Modus: hier wuerde dein Hook zu HA/MQTT/Shelly laufen.)")


def rueckfrage(text: str) -> int:
    print(f"RUECKFRAGE: {text}")
    return 2


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("text", help="Befehl, z.B. 'Mach das Licht im Wohnzimmer aus'")
    ap.add_argument("--url", default=os.environ.get("LAYA_URL"),
                    help="laya-local API (oder Env LAYA_URL)")
    ap.add_argument("--fragen", default=str(DEFAULT_QUESTIONS),
                    help="Pfad zu fragen.json")
    ap.add_argument("--min-conf", type=float, default=0.8,
                    help="Mindest-Confidence zum direkten Schalten")
    args = ap.parse_args(argv)

    if not args.url:
        print("Fehler: --url oder Env LAYA_URL fehlt, "
              "z.B. http://192.168.1.100:8080/api/predict", file=sys.stderr)
        return 1

    try:
        questions = json.loads(Path(args.fragen).read_text(encoding="utf-8"))
        result = laya_predict(args.url, args.text, questions)
        answers = result["answers"]
        intent = answers["intent"]["choice"]
        conf = float(answers["intent"]["confidence"])
        raum = answers["raum"]["choice"]
        sec = float(answers["sicherheitsrelevant"]["noul"])
    except Exception:
        traceback.print_exc()  # komplette Kette, nicht nur letzte Zeile
        return 1

    print(json.dumps(answers, indent=2, ensure_ascii=False))

    if sec > 0.5 or intent == "sicherheit":
        return rueckfrage("Sicherheitsrelevant (Schloss/Alarm/Garage/Kamera) - "
                          "bitte ausdrucklich bestaetigen, es wurde NICHTS geschaltet.")
    if conf < args.min_conf or raum == "unklar":
        return rueckfrage(f"Unsicher (intent={intent} conf={conf:.2f} raum={raum}) - "
                          "bitte praezisieren.")
    schalten(intent, raum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
