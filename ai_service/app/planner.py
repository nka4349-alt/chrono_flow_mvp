from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple
import json
import re
import unicodedata

from .llm_backend import CONFIG, generate_json, health_status


ALLOWED_INTENTS = {
    "meeting",
    "alignment",
    "review",
    "approval",
    "kickoff",
    "friend_meetup",
    "family_plan",
    "follow_up",
    "general",
}
ALLOWED_CATEGORIES = {"work", "friend", "family", "group", "other"}
ALLOWED_PROFILES = {"work", "social", "family", "group"}
WEEKDAY_MAP = {
    "月": 0,
    "月曜": 0,
    "月曜日": 0,
    "火": 1,
    "火曜": 1,
    "火曜日": 1,
    "水": 2,
    "水曜": 2,
    "水曜日": 2,
    "木": 3,
    "木曜": 3,
    "木曜日": 3,
    "金": 4,
    "金曜": 4,
    "金曜日": 4,
    "土": 5,
    "土曜": 5,
    "土曜日": 5,
    "日": 6,
    "日曜": 6,
    "日曜日": 6,
}
_DURATION_RE = re.compile(r"(?P<value>\d{1,3})\s*分")
_HOUR_HALF_RE = re.compile(r"(?P<hours>\d{1,2})\s*時間\s*半")
_HOUR_AND_MIN_RE = re.compile(r"(?P<hours>\d{1,2})\s*時間\s*(?P<minutes>\d{1,2})\s*分")
_HOUR_RE = re.compile(r"(?P<hours>\d{1,2})\s*時間")


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "")).strip().lower()


def compact_events(events: List[Dict[str, Any]], limit: int = 8) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for event in (events or [])[:limit]:
        if not isinstance(event, dict):
            continue
        rows.append(
            {
                "title": event.get("title"),
                "start_at": event.get("start_at"),
                "end_at": event.get("end_at"),
                "group_names": event.get("group_names") or [],
                "all_day": bool(event.get("all_day")),
            }
        )
    return rows


def compact_contacts(context: Dict[str, Any], limit: int = 12) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for contact in (context.get("contacts") or [])[:limit]:
        if not isinstance(contact, dict):
            continue
        name = (contact.get("display_name") or "").strip()
        if not name:
            continue
        rows.append(
            {
                "id": contact.get("id"),
                "display_name": name,
                "relation_type": contact.get("relation_type"),
                "timezone": contact.get("timezone"),
                "preferred_duration_minutes": contact.get("preferred_duration_minutes"),
            }
        )
    return rows


def compact_friends(context: Dict[str, Any], limit: int = 12) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for friend in (context.get("friends") or [])[:limit]:
        if not isinstance(friend, dict):
            continue
        name = (friend.get("name") or friend.get("display_name") or "").strip()
        if not name:
            continue
        rows.append(
            {
                "id": friend.get("id"),
                "name": name,
                "email": friend.get("email"),
            }
        )
    return rows


def compact_recent_direct_messages(context: Dict[str, Any], limit: int = 10) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for message in (context.get("recent_direct_messages") or [])[-limit:]:
        if not isinstance(message, dict):
            continue
        rows.append(
            {
                "peer_name": message.get("peer_name"),
                "user_name": message.get("user_name"),
                "body": message.get("body"),
                "created_at": message.get("created_at"),
            }
        )
    return rows


def compact_recent_messages(context: Dict[str, Any], scope: str, limit: int = 6) -> List[Dict[str, Any]]:
    if scope == "group":
        source = context.get("recent_group_messages") or []
        rows = []
        for message in source[-limit:]:
            if not isinstance(message, dict):
                continue
            rows.append(
                {
                    "author": message.get("author_name") or message.get("author"),
                    "body": message.get("body"),
                    "created_at": message.get("created_at"),
                }
            )
        return rows

    source = context.get("ai_recent_messages") or []
    rows = []
    for message in source[-limit:]:
        if not isinstance(message, dict):
            continue
        rows.append(
            {
                "role": message.get("role"),
                "body": message.get("body"),
                "created_at": message.get("created_at"),
            }
        )
    return rows


def planner_context_summary(scope: str, user_message: str, context: Dict[str, Any]) -> str:
    payload = {
        "scope": scope,
        "timezone": context.get("timezone") or "Asia/Tokyo",
        "now": context.get("now"),
        "user_message": user_message,
        "group": {
            "id": (context.get("group") or {}).get("id"),
            "name": (context.get("group") or {}).get("name"),
        }
        if scope == "group"
        else None,
        "personal_events": compact_events(context.get("personal_events") or [], limit=10),
        "candidate_group_events": compact_events(context.get("candidate_group_events") or [], limit=8),
        "contacts": compact_contacts(context, limit=12),
        "friends": compact_friends(context, limit=12),
        "recent_direct_messages": compact_recent_direct_messages(context, limit=10),
        "recent_messages": compact_recent_messages(context, scope=scope),
    }
    return json.dumps(payload, ensure_ascii=False)


def _next_week_range(now: datetime) -> List[int]:
    weekday = now.weekday()
    first = 7 - weekday
    return list(range(max(first, 1), max(first, 1) + 7))


def explicit_day_offsets_from_text(text: str, now: datetime) -> Tuple[Optional[List[int]], bool]:
    normalized = normalize_text(text)
    if not normalized:
        return None, False

    if "明々後日" in normalized or "しあさって" in normalized:
        return [3], True
    if "明後日" in normalized or "あさって" in normalized:
        return [2], True
    if "明日" in normalized or "あした" in normalized:
        return [1], True
    if "今日" in normalized or "きょう" in normalized:
        return [0], True

    if "今週中" in normalized:
        offsets = [offset for offset in range(0, 7) if (now + timedelta(days=offset)).weekday() < 5]
        return offsets[:5], False
    if "平日" in normalized:
        offsets = [offset for offset in range(0, 14) if (now + timedelta(days=offset)).weekday() < 5]
        return offsets[:7], False
    if "来週前半" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() <= 2][:4], True
    if "来週後半" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() >= 3][:4], True
    if "週明け" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() <= 1][:3], True
    if "来週末" in normalized:
        offsets = [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() >= 5]
        return offsets[:2], True
    if "今週末" in normalized or "週末" in normalized or "土日" in normalized:
        offsets = [offset for offset in range(0, 14) if (now + timedelta(days=offset)).weekday() >= 5]
        return offsets[:4] or [5], True

    matched_weekday = None
    for token, weekday in WEEKDAY_MAP.items():
        if token in normalized:
            matched_weekday = weekday
            break

    if matched_weekday is None:
        if "来週" in normalized:
            return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() < 5][:5], False
        return None, False

    current_weekday = now.weekday()
    if "再来週" in normalized:
        base = (7 - current_weekday) + 7
        return [base + matched_weekday], True
    if "来週" in normalized:
        base = 7 - current_weekday
        return [base + matched_weekday], True

    delta = (matched_weekday - current_weekday) % 7
    return [delta], True


def explicit_duration_minutes_from_text(text: str) -> Optional[int]:
    normalized = normalize_text(text)
    if not normalized:
        return None

    match = _HOUR_AND_MIN_RE.search(normalized)
    if match:
        minutes = int(match.group("hours")) * 60 + int(match.group("minutes"))
        return max(15, min(minutes, 240))

    match = _HOUR_HALF_RE.search(normalized)
    if match:
        minutes = int(match.group("hours")) * 60 + 30
        return max(15, min(minutes, 240))

    match = _HOUR_RE.search(normalized)
    if match:
        minutes = int(match.group("hours")) * 60
        return max(15, min(minutes, 240))

    match = _DURATION_RE.search(normalized)
    if match:
        minutes = int(match.group("value"))
        return max(15, min(minutes, 240))

    return None


def _system_prompt() -> str:
    return (
        "You are the local planning model for ChronoFlow. "
        "Return one JSON object only. No markdown, no prose. "
        "Interpret Japanese scheduling requests into a structured plan. "
        "Prefer work/business intent when the user mentions meetings, reviews, kickoff, alignment, approval, or scheduling in free time, "
        "unless the user explicitly mentions family/friends/contact names or social words. "
        "Use contacts, friends, and recent direct-message peer names to infer contact_name when obvious. "
        "Resolve relative dates against the provided now/tz. "
        "For explicit date words like 今日/明日/明後日/来週火曜/来週末, set strict_day=true and day_offsets accordingly. "
        "When the user did not specify a date, leave day_offsets empty. "
        "Infer duration_minutes from phrases like 30分, 1時間, 1時間半 when possible. "
        "Allowed intent values: meeting, alignment, review, approval, kickoff, friend_meetup, family_plan, follow_up, general. "
        "Allowed category values: work, friend, family, group, other. "
        "Allowed profile values: work, social, family, group. "
        "Keys: intent, category, profile, duration_minutes, day_offsets, strict_day, contact_name, assistant_message, confidence."
    )


def _user_prompt(scope: str, user_message: str, context: Dict[str, Any]) -> str:
    return (
        "Use the following JSON context.\n"
        "Return JSON only. Example:\n"
        '{"intent":"meeting","category":"work","profile":"work","duration_minutes":45,'
        '"day_offsets":[2],"strict_day":true,"contact_name":null,'
        '"assistant_message":"明後日の候補を優先して出します。",'
        '"confidence":0.92}\n\n'
        f"context_json:\n{planner_context_summary(scope, user_message, context)}"
    )


def _normalize_plan(raw: Dict[str, Any], scope: str, user_message: str, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict):
        return None

    plan: Dict[str, Any] = {
        "intent": raw.get("intent") if raw.get("intent") in ALLOWED_INTENTS else None,
        "category": raw.get("category") if raw.get("category") in ALLOWED_CATEGORIES else None,
        "profile": raw.get("profile") if raw.get("profile") in ALLOWED_PROFILES else None,
        "duration_minutes": None,
        "day_offsets": [],
        "strict_day": bool(raw.get("strict_day")),
        "contact_name": (raw.get("contact_name") or "").strip() or None,
        "assistant_message": (raw.get("assistant_message") or "").strip() or None,
        "confidence": 0.0,
        "source": "llm",
    }

    try:
        duration = int(raw.get("duration_minutes"))
        if 15 <= duration <= 240:
            plan["duration_minutes"] = duration
    except Exception:
        plan["duration_minutes"] = None

    if plan["duration_minutes"] is None:
        plan["duration_minutes"] = explicit_duration_minutes_from_text(user_message)

    day_offsets: List[int] = []
    for value in raw.get("day_offsets") or []:
        try:
            offset = int(value)
        except Exception:
            continue
        if 0 <= offset <= 21 and offset not in day_offsets:
            day_offsets.append(offset)
    plan["day_offsets"] = day_offsets[:7]

    try:
        plan["confidence"] = round(float(raw.get("confidence") or 0.0), 3)
    except Exception:
        plan["confidence"] = 0.0

    if not plan["intent"] and plan["category"] == "work":
        plan["intent"] = "meeting"
    if not plan["profile"]:
        plan["profile"] = "work" if plan["category"] in {None, "work", "group"} else "social" if plan["category"] == "friend" else "family"

    now_value = context.get("now")
    parsed_now = None
    if now_value:
        try:
            parsed_now = datetime.fromisoformat(str(now_value).replace("Z", "+00:00"))
        except Exception:
            parsed_now = None
    fallback_offsets, fallback_strict = explicit_day_offsets_from_text(user_message, now=parsed_now or datetime.now())
    if not plan["day_offsets"] and fallback_offsets:
        plan["day_offsets"] = fallback_offsets
    if not plan["strict_day"] and fallback_strict:
        plan["strict_day"] = True

    if not any([plan["intent"], plan["day_offsets"], plan["contact_name"], plan["assistant_message"], plan["duration_minutes"]]):
        return None

    return plan


def plan_message(scope: str, user_message: str, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    raw = generate_json(_system_prompt(), _user_prompt(scope, user_message, context))
    plan = _normalize_plan(raw or {}, scope=scope, user_message=user_message, context=context)
    if not plan:
        return None
    plan["_provider"] = f"{CONFIG.backend}:{CONFIG.model}" if CONFIG.enabled and CONFIG.model else None
    return plan


def llm_plan(context: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not context:
        return None
    plan = context.get("_llm_plan")
    return plan if isinstance(plan, dict) else None


def planned_intent(context: Optional[Dict[str, Any]]) -> Optional[str]:
    plan = llm_plan(context)
    return (plan or {}).get("intent") or None


def planned_duration_minutes(context: Optional[Dict[str, Any]]) -> Optional[int]:
    plan = llm_plan(context)
    value = (plan or {}).get("duration_minutes")
    return value if isinstance(value, int) else None


def planned_day_offsets(context: Optional[Dict[str, Any]]) -> List[int]:
    plan = llm_plan(context)
    values = (plan or {}).get("day_offsets") or []
    return [value for value in values if isinstance(value, int)]


def planned_strict_day(context: Optional[Dict[str, Any]]) -> bool:
    plan = llm_plan(context)
    return bool((plan or {}).get("strict_day"))


def planned_contact_name(context: Optional[Dict[str, Any]]) -> Optional[str]:
    plan = llm_plan(context)
    value = (plan or {}).get("contact_name")
    return value if value else None


def planned_assistant_message(context: Optional[Dict[str, Any]]) -> Optional[str]:
    plan = llm_plan(context)
    value = (plan or {}).get("assistant_message")
    return value if value else None


def planned_provider(context: Optional[Dict[str, Any]]) -> Optional[str]:
    plan = llm_plan(context)
    value = (plan or {}).get("_provider")
    return value if value else None


def current_llm_health() -> Dict[str, Any]:
    return health_status()
