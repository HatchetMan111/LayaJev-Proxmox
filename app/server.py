"""laya-local: lokale FastAPI-Huelle um Upstream-laya (CPU, lazy Router).

Keine Modell-Downloads beim Import. Der Router wird erst beim ersten
POST /api/predict gebaut (dauert beim Erstaufruf 30-90s: Download + Cold-Build).
"""
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
        raise HTTPException(
            status_code=500, detail=f"{type(exc).__name__}: {exc}"
        ) from exc


STATIC = Path(__file__).parent / "static"


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


def main():
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8080)
