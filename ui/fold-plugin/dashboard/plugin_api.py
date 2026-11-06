"""Hermes Fold 파일 첨부 — POST /api/plugins/fold-upload/upload?name=<파일 이름>  (본문 = 파일 바이트 그대로)

* Hermes 대시보드의 /api/ 인증(로그인 쿠키 · 세션 토큰)을 그대로 거침 → 로그인한 화면만 업로드 가능
* 저장 위치: 작업 폴더(HERMES_WRITE_SAFE_ROOT, 없으면 ~/work) 의 uploads/ — 에이전트가 읽을 수 있는 곳
* 이름은 안전한 글자만 남기고 시각을 붙여 덮어쓰기 없음 · 최대 25MB · 권한 600
"""
from __future__ import annotations

import os
import re
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request

router = APIRouter()
MAX_BYTES = 25 * 1024 * 1024


def _upload_dir() -> Path:
    root = os.environ.get("HERMES_WRITE_SAFE_ROOT") or str(Path.home() / "work")
    d = Path(root).expanduser() / "uploads"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def _safe_name(name: str) -> str:
    base = os.path.basename(str(name or "")).strip()
    base = re.sub(r"[^\w.\-]+", "_", base).lstrip(".")
    return (base[-80:] if base else "file")


@router.post("/upload")
async def upload(request: Request, name: str = "file"):
    d = _upload_dir()
    safe = _safe_name(name)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = d / f"{stamp}_{safe}"
    k = 1
    while path.exists():
        k += 1
        path = d / f"{stamp}-{k}_{safe}"
    size = 0
    try:
        with open(path, "xb") as f:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_BYTES:
                    raise HTTPException(status_code=413, detail="파일이 너무 커요 (최대 25MB)")
                f.write(chunk)
        if size == 0:
            raise HTTPException(status_code=400, detail="빈 파일이에요")
        os.chmod(path, 0o600)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return {"ok": True, "path": str(path), "name": safe, "size": size}
