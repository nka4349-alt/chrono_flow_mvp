from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional
import json
import os
import re
import urllib.error
import urllib.request


TRUE_VALUES = {"1", "true", "yes", "on", "enabled"}


@dataclass(frozen=True)
class LLMConfig:
    enabled: bool
    backend: str
    base_url: str
    model: str
    timeout_sec: float
    temperature: float

    @classmethod
    def from_env(cls) -> "LLMConfig":
        explicit_enabled = os.getenv("AI_LLM_ENABLED")
        model = (os.getenv("AI_LLM_MODEL") or os.getenv("OLLAMA_MODEL") or "").strip()
        enabled = bool(model)
        if explicit_enabled is not None:
            enabled = explicit_enabled.strip().lower() in TRUE_VALUES
        return cls(
            enabled=enabled and bool(model),
            backend=(os.getenv("AI_LLM_BACKEND") or "ollama").strip().lower(),
            base_url=(os.getenv("AI_LLM_BASE_URL") or os.getenv("OLLAMA_HOST") or "http://127.0.0.1:11434").rstrip("/"),
            model=model,
            timeout_sec=max(3.0, float(os.getenv("AI_LLM_TIMEOUT") or "20")),
            temperature=float(os.getenv("AI_LLM_TEMPERATURE") or "0.1"),
        )


CONFIG = LLMConfig.from_env()


def config_dict() -> Dict[str, Any]:
    return {
        "enabled": CONFIG.enabled,
        "backend": CONFIG.backend,
        "base_url": CONFIG.base_url,
        "model": CONFIG.model,
        "timeout_sec": CONFIG.timeout_sec,
    }


def _http_post_json(url: str, payload: Dict[str, Any], timeout_sec: float) -> Dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout_sec) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw)


def _http_get_json(url: str, timeout_sec: float) -> Dict[str, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    with urllib.request.urlopen(request, timeout=timeout_sec) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw)


_JSON_BLOCK_RE = re.compile(r"\{.*\}", re.S)


def extract_json_object(text: str) -> Optional[Dict[str, Any]]:
    if not text:
        return None

    stripped = text.strip()
    try:
        parsed = json.loads(stripped)
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        pass

    match = _JSON_BLOCK_RE.search(stripped)
    if not match:
        return None

    candidate = match.group(0)
    try:
        parsed = json.loads(candidate)
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None


def generate_json(system_prompt: str, user_prompt: str) -> Optional[Dict[str, Any]]:
    if not CONFIG.enabled or CONFIG.backend != "ollama" or not CONFIG.model:
        return None

    chat_payload = {
        "model": CONFIG.model,
        "stream": False,
        "format": "json",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "options": {
            "temperature": CONFIG.temperature,
        },
    }

    try:
        data = _http_post_json(f"{CONFIG.base_url}/api/chat", chat_payload, timeout_sec=CONFIG.timeout_sec)
        content = (((data or {}).get("message") or {}).get("content") or "").strip()
        parsed = extract_json_object(content)
        if parsed:
            return parsed
    except Exception:
        pass

    generate_payload = {
        "model": CONFIG.model,
        "stream": False,
        "prompt": user_prompt,
        "system": system_prompt,
        "options": {
            "temperature": CONFIG.temperature,
        },
    }
    try:
        data = _http_post_json(f"{CONFIG.base_url}/api/generate", generate_payload, timeout_sec=CONFIG.timeout_sec)
        content = (data or {}).get("response") or ""
        return extract_json_object(content)
    except Exception:
        return None


def health_status() -> Dict[str, Any]:
    base = {
        "enabled": CONFIG.enabled,
        "backend": CONFIG.backend,
        "model": CONFIG.model,
        "base_url": CONFIG.base_url,
        "ready": False,
    }
    if not CONFIG.enabled or CONFIG.backend != "ollama" or not CONFIG.model:
        return base

    try:
        data = _http_get_json(f"{CONFIG.base_url}/api/tags", timeout_sec=min(CONFIG.timeout_sec, 5.0))
        models = [((entry or {}).get("name") or "") for entry in (data or {}).get("models") or []]
        base["ready"] = CONFIG.model in models or any(name.startswith(f"{CONFIG.model}:") for name in models)
    except Exception:
        base["ready"] = False
    return base
