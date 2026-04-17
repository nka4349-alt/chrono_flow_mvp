# ChronoFlow AI Service (local only)

This service is designed to run locally or on an internal network.
It does not require any external LLM API.

It can now run in three layers:
- rules fallback (default)
- local LLM planner (optional)
- deterministic tool use + scheduling solver (always on)

## Start

```bash
cd ai_service
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8001 --reload
```

Rails side:

```bash
AI_SERVICE_URL=http://127.0.0.1:8001 bin/rails server
```

## Optional local LLM mode

ChronoFlow keeps the existing Rails API contract and swaps only the planner inside FastAPI.

Example with a local Ollama model:

```bash
cd ai_service
source .venv/bin/activate
AI_LLM_ENABLED=1 \
AI_LLM_BACKEND=ollama \
AI_LLM_BASE_URL=http://127.0.0.1:11434 \
AI_LLM_MODEL=<your_local_instruct_model> \
uvicorn app.main:app --host 127.0.0.1 --port 8001 --reload
```

Health check now returns both the rules provider and local LLM readiness:

```bash
curl http://127.0.0.1:8001/health
```

Example response:

```json
{
  "ok": "true",
  "provider": "rules-v4-work-intent",
  "llm_enabled": "true",
  "llm_backend": "ollama",
  "llm_model": "...",
  "llm_ready": "true"
}
```

When local LLM mode is enabled, the model is used for:
- intent understanding
- relative date understanding such as 今日 / 明日 / 明後日 / 来週火曜
- optional contact name resolution hints
- assistant phrasing

Candidate slot generation still uses the deterministic scheduler in `app/main.py`, so timing stays constraint-safe.
Tool use is now wired in for date constraints, personal calendar summarization, and social/contact resolution before recommendation building.

## Current behavior

- Group scope: analyzes recent group chat + latest user message and suggests reply text plus draft events.
- Home scope: suggests upcoming group events to copy into the personal calendar, or draft events when the user asks for scheduling help.
- No external APIs are used.

## Extension points

The service already supports an optional local LLM planner, deterministic tool use, and rules fallback while keeping the existing Rails API contract.
You can later swap the local backend again (Ollama, vLLM, llama.cpp, etc.) without changing the Rails side.
