from __future__ import annotations

from datetime import datetime, timedelta, time, date
from typing import Any, Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo
import re
import unicodedata

from fastapi import FastAPI
from pydantic import BaseModel, Field

from .planner import (
    current_llm_health,
    explicit_day_offsets_from_text,
    plan_message,
    planned_assistant_message,
    planned_contact_name,
    planned_day_offsets,
    planned_duration_minutes,
    planned_intent,
    planned_provider,
    planned_strict_day,
)
from .tool_registry import TOOL_USE_VERSION, run_tools
from .ranker import RANKER_VERSION, rerank_recommendations

POLICY_VERSION = "rules-v4-work-intent"
DEFAULT_TZ = "Asia/Tokyo"

app = FastAPI(title="ChronoFlow AI Service", version="0.6.0")


class ChatRequest(BaseModel):
    scope: str = Field(pattern="^(home|group)$")
    user_message: str = ""
    refresh_only: bool = False
    context: Dict[str, Any]


class Recommendation(BaseModel):
    kind: str
    title: str
    description: Optional[str] = None
    reason: Optional[str] = None
    start_at: Optional[str] = None
    end_at: Optional[str] = None
    all_day: bool = False
    source_event_id: Optional[int] = None
    payload: Dict[str, Any] = Field(default_factory=dict)


class ChatResponse(BaseModel):
    provider: str = POLICY_VERSION
    assistant_message: str
    recommendations: List[Recommendation] = Field(default_factory=list)
    tool_invocations: List[Dict[str, Any]] = Field(default_factory=list)


INTENT_RULES = [
    {
        "intent": "meeting",
        "keywords": ["会議", "ミーティング", "meeting", "mtg", "打ち合わせ", "打合せ", "定例", "1on1", "面談"],
        "title": "会議",
        "duration": 45,
        "reason": "会議系の依頼なので、まず業務の打ち合わせ枠を押さえるのが自然です。",
        "reply": "承知しました。まず会議を入れやすい時間を先に確保します。",
        "profile": "work",
        "category": "work",
        "color": "#2563eb",
    },
    {
        "intent": "alignment",
        "keywords": ["調整", "相談", "確認", "すり合わせ", "整理", "打ち合わせ"],
        "title": "関係者調整",
        "duration": 30,
        "reason": "調整や確認の流れがあり、短時間で合わせる価値が高そうです。",
        "reply": "承知しました。まず関係者調整の時間を30分ほど確保します。",
        "profile": "work",
        "category": "work",
        "color": "#3b82f6",
    },
    {
        "intent": "review",
        "keywords": ["レビュー", "見て", "確認会", "レビュー会", "レビューして"],
        "title": "レビュー会議",
        "duration": 45,
        "reason": "レビュー依頼の文脈があるため、確認会を先に置くと進めやすそうです。",
        "reply": "承知しました。レビュー会議を先に設定して進めます。",
        "profile": "work",
        "category": "work",
        "color": "#8b5cf6",
    },
    {
        "intent": "approval",
        "keywords": ["承認", "上司", "合議", "稟議", "相談して", "上に", "決裁"],
        "title": "合議",
        "duration": 45,
        "reason": "承認や上位相談が必要そうなので、合議の場を先に置くと安全です。",
        "reply": "承知しました。承認前提の合議枠を先に押さえます。",
        "profile": "work",
        "category": "work",
        "color": "#06b6d4",
    },
    {
        "intent": "kickoff",
        "keywords": ["お願い", "企画", "キックオフ", "進めて", "着手", "開始"],
        "title": "企画キックオフ",
        "duration": 60,
        "reason": "新規着手の流れがあるため、最初の整理会を入れると迷いが減りそうです。",
        "reply": "承知しました。まずキックオフの場を設定して進めます。",
        "profile": "work",
        "category": "work",
        "color": "#3b82f6",
    },
    {
        "intent": "friend_meetup",
        "keywords": ["友達", "友人", "約束", "遊び", "会いたい", "飲み", "ご飯", "ごはん", "ランチ", "ディナー", "会う", "会える", "食事"],
        "title": "友達との予定",
        "duration": 90,
        "reason": "友達との予定は夕方以降か休日に置くと合わせやすそうです。",
        "reply": "よさそうです。友達との予定を入れやすい時間を先に押さえます。",
        "profile": "social",
        "category": "friend",
        "color": "#f97316",
    },
    {
        "intent": "family_plan",
        "keywords": ["家族", "親", "母", "父", "子ども", "子供", "夫", "妻", "実家", "送り迎え", "行事", "通院", "家の用事", "会う", "食事"],
        "title": "家族の予定",
        "duration": 90,
        "reason": "家族の予定は平日夕方か休日に寄せると組みやすそうです。",
        "reply": "家族の予定を入れやすい時間帯で候補を出します。",
        "profile": "family",
        "category": "family",
        "color": "#22c55e",
    },
    {
        "intent": "follow_up",
        "keywords": ["進捗", "フォロー", "確認", "追い", "詰め", "再確認"],
        "title": "進捗確認",
        "duration": 30,
        "reason": "次のアクションを止めないため、短い確認枠を入れておくと進めやすそうです。",
        "reply": "承知しました。まず短い進捗確認の時間を押さえて進めます。",
        "profile": "work",
        "category": "work",
        "color": "#3b82f6",
    },
]

HOME_TRIGGER_KEYWORDS = [
    "予定", "会議", "ミーティング", "meeting", "mtg", "打ち合わせ", "打合せ", "相談", "調整", "レビュー", "キックオフ", "入れ", "空き時間", "いつ",
    "友達", "友人", "家族", "親", "子ども", "子供", "母", "父", "ランチ", "ディナー", "約束",
    "会う", "会える", "食事", "送り迎え", "付き添い", "通院",
    "遊び", "遊ぶ", "遊びに行く", "出かけ", "出掛け", "お出かけ", "おでかけ", "旅行", "ドライブ",
]

FAMILY_TAGS = ["家族", "実家", "親", "母", "父", "子", "子ども", "子供", "夫", "妻"]
FRIEND_TAGS = ["友達", "友人", "同級生", "サークル", "飲み", "ランチ", "ディナー", "食事", "ご飯", "ごはん", "遊び", "遊ぶ", "遊びに行く", "出かけ", "出掛け", "お出かけ", "おでかけ", "旅行", "ドライブ"]
WORK_TAGS = ["部署", "チーム", "プロジェクト", "企画", "業務", "会議", "ミーティング", "meeting", "mtg", "打ち合わせ", "打合せ", "レビュー", "調整", "相談", "合議", "キックオフ"]
BUSINESS_STRONG_KEYWORDS = ["会議", "ミーティング", "meeting", "mtg", "打ち合わせ", "打合せ", "レビュー", "レビュー会", "合議", "稟議", "キックオフ", "定例", "1on1", "面談", "商談"]
BUSINESS_SOFT_KEYWORDS = ["相談", "調整", "確認", "すり合わせ", "整理", "進捗", "フォロー", "再確認"]

RELATION_KEYWORDS = {
    "friend": ["友達", "友人", "同級生", "親友"],
    "family": ["家族", "実家"],
    "parent": ["親", "母", "父", "お母さん", "お父さん"],
    "child": ["子ども", "子供", "娘", "息子"],
    "partner": ["夫", "妻", "パートナー", "彼氏", "彼女"],
    "colleague": ["同僚", "仕事仲間", "先輩", "後輩"],
    "other": [],
}

RELATION_CATEGORY_MAP = {
    "friend": "friend",
    "family": "family",
    "parent": "family",
    "child": "family",
    "partner": "family",
    "colleague": "work",
    "other": "other",
}

GENERIC_CONTACT_RELATION_KEYWORDS = {"友達", "友人", "同級生", "親友", "家族", "実家"}
OUTING_DESTINATION_RE = re.compile(
    r"(?P<dest>[A-Za-zぁ-んァ-ヶ一-龯][A-Za-z0-9ぁ-んァ-ヶー一-龯・･/／._\-]{0,15}?)(?:に|へ)(?:行く|いく|行きたい|行きます|遊びに行く|出かける|出掛ける|お出かけする|旅行する)"
)


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "")).strip().lower()


def tz_from_name(raw: Optional[str]) -> ZoneInfo:
    value = (raw or "").strip()
    aliases = {"tokyo": "Asia/Tokyo", "osaka": "Asia/Tokyo", "jst": "Asia/Tokyo", "utc": "UTC"}
    candidates = [value, DEFAULT_TZ, "UTC"]
    for cand in candidates:
        if not cand:
            continue
        cand = aliases.get(cand.lower(), cand)
        try:
            return ZoneInfo(cand)
        except Exception:
            continue
    return ZoneInfo(DEFAULT_TZ)


def tz_from_context(context: Dict[str, Any]) -> ZoneInfo:
    return tz_from_name(context.get("timezone"))


def parse_iso(value: Optional[str], tz: Optional[ZoneInfo] = None) -> Optional[datetime]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=tz or ZoneInfo(DEFAULT_TZ))
    return dt.astimezone(tz) if tz else dt


def iso(dt: Optional[datetime]) -> Optional[str]:
    if not dt:
        return None
    return dt.isoformat()


def safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


def local_now(context: Dict[str, Any]) -> datetime:
    tz = tz_from_context(context)
    return parse_iso(context.get("now"), tz) or datetime.now(tz)


def combined_group_text(context: Dict[str, Any], user_message: str) -> str:
    recent = context.get("recent_group_messages") or []
    parts = [m.get("body", "") for m in recent[-8:]]
    if user_message:
        parts.append(user_message)
    return "\n".join(parts)


def context_contacts(context: Dict[str, Any]) -> List[Dict[str, Any]]:
    contacts: List[Dict[str, Any]] = []
    for contact in context.get("contacts") or []:
        if not isinstance(contact, dict):
            continue
        if (contact.get("display_name") or "").strip():
            contacts.append(contact)
    return contacts


def contact_name(contact: Optional[Dict[str, Any]]) -> str:
    if not contact:
        return ""
    return (contact.get("display_name") or "").strip()


def contact_name_norm(contact: Optional[Dict[str, Any]]) -> str:
    return normalize_text(contact_name(contact))


def contains_any(text: str, keywords: List[str]) -> bool:
    normalized = normalize_text(text)
    return any(normalize_text(keyword) in normalized for keyword in keywords if normalize_text(keyword))


def explicit_contact_name_in_text(text: str, contact: Optional[Dict[str, Any]]) -> bool:
    name_norm = contact_name_norm(contact)
    return bool(name_norm and name_norm in normalize_text(text))


def specific_relation_keywords_for_contact(contact: Optional[Dict[str, Any]]) -> List[str]:
    keywords: List[str] = []
    for keyword in relation_keywords_for_contact(contact):
        keyword_norm = normalize_text(keyword)
        if not keyword_norm or keyword_norm in {normalize_text(value) for value in GENERIC_CONTACT_RELATION_KEYWORDS}:
            continue
        keywords.append(keyword_norm)
    return keywords


def contact_reference_strength(text: str, contact: Optional[Dict[str, Any]], context: Optional[Dict[str, Any]] = None) -> int:
    normalized = normalize_text(text)
    if not contact:
        return 0
    if explicit_contact_name_in_text(normalized, contact):
        return 3
    if any(keyword in normalized for keyword in specific_relation_keywords_for_contact(contact)):
        return 2

    planned_name = normalize_text(planned_contact_name(context) or "")
    name_norm = contact_name_norm(contact)
    if planned_name and name_norm and (planned_name in name_norm or name_norm in planned_name):
        return 2

    social = (tool_results(context).get("social_resolver") or {}) if context else {}
    matched_alias = normalize_text((social.get("matched_alias") or ""))
    if matched_alias and matched_alias not in {normalize_text(value) for value in GENERIC_CONTACT_RELATION_KEYWORDS} and name_norm:
        if matched_alias == name_norm or matched_alias in name_norm or name_norm in matched_alias:
            return 2

    return 0


def should_personalize_contact(text: str, contact: Optional[Dict[str, Any]], context: Optional[Dict[str, Any]] = None) -> bool:
    category = contact_category(contact)
    if category == "work":
        return bool(contact)
    return contact_reference_strength(text, contact, context=context) >= 2


def extract_outing_destination(text: str) -> Optional[str]:
    normalized = unicodedata.normalize("NFKC", text or "").strip()
    if not normalized:
        return None
    match = OUTING_DESTINATION_RE.search(normalized)
    if not match:
        return None
    destination = (match.group("dest") or "").strip()
    for token in ["と", "で", "を", "から", "まで"]:
        if token in destination:
            destination = destination.split(token)[-1]
    destination = re.sub(r"^.*?(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}時(?:\d{1,2}分?|半)?)[にへ]?", "", destination)
    destination = destination.lstrip("にへ").strip(" ・･/／._-")
    if not destination:
        return None
    if re.fullmatch(r"\d{1,2}(?::\d{2})?", destination):
        return None
    return destination


def social_keywords_for_category(category: str) -> List[str]:
    if category == "family":
        return [*FAMILY_TAGS, "送り迎え", "通院", "付き添い", "会う", "会える", "食事", "ご飯", "ごはん", "ランチ", "ディナー"]
    if category == "friend":
        return [*FRIEND_TAGS, "約束", "遊び", "会う", "会える", "食事", "ご飯", "ごはん", "ランチ", "ディナー", "飲み"]
    return []


def business_signal_level(text: str) -> int:
    normalized = normalize_text(text)
    if contains_any(normalized, BUSINESS_STRONG_KEYWORDS):
        return 2
    if contains_any(normalized, BUSINESS_SOFT_KEYWORDS):
        return 1
    return 0


def explicit_social_keyword_signal(text: str, category: Optional[str] = None) -> bool:
    normalized = normalize_text(text)
    target_categories = [category] if category else ["family", "friend"]
    return any(contains_any(normalized, social_keywords_for_category(target)) for target in target_categories)


def explicit_social_signal(text: str, context: Optional[Dict[str, Any]] = None, category: Optional[str] = None) -> bool:
    normalized = normalize_text(text)
    target_categories = [category] if category else ["family", "friend"]

    if explicit_social_keyword_signal(normalized, category=category):
        return True

    if context:
        for contact in context_contacts(context):
            contact_cat = contact_category(contact)
            if contact_cat not in {"family", "friend"}:
                continue
            if category and contact_cat != category:
                continue
            if explicit_contact_name_in_text(normalized, contact):
                return True

        if category in {None, "friend"}:
            for friend in context.get("friends") or []:
                if not isinstance(friend, dict):
                    continue
                friend_name = normalize_text(friend.get("name") or "")
                if friend_name and friend_name in normalized:
                    return True

    return False


def explicit_contact_signal(text: str, contact: Optional[Dict[str, Any]]) -> bool:
    normalized = normalize_text(text)
    if not contact:
        return False
    if explicit_contact_name_in_text(normalized, contact):
        return True

    category = contact_category(contact)
    keywords = list(specific_relation_keywords_for_contact(contact))
    if category == "work":
        keywords += BUSINESS_STRONG_KEYWORDS + BUSINESS_SOFT_KEYWORDS + WORK_TAGS

    return contains_any(normalized, keywords)


def should_prioritize_work_intent(text: str, context: Optional[Dict[str, Any]] = None) -> bool:
    plan_intent = planned_intent(context)
    if plan_intent in {"meeting", "alignment", "review", "approval", "kickoff", "follow_up"}:
        return True
    if context and (context.get("_llm_plan") or {}).get("category") in {"friend", "family"}:
        return False

    normalized = normalize_text(text)
    return business_signal_level(normalized) > 0 and not explicit_social_keyword_signal(normalized)


def contact_category(contact: Optional[Dict[str, Any]]) -> str:
    relation = ((contact or {}).get("relation_type") or "").strip()
    return RELATION_CATEGORY_MAP.get(relation, relation or "other")


def relation_keywords_for_contact(contact: Optional[Dict[str, Any]]) -> List[str]:
    relation = ((contact or {}).get("relation_type") or "").strip()
    keywords = list(RELATION_KEYWORDS.get(relation, []))
    name = contact_name(contact)
    if name:
        keywords.append(name)
    return keywords


def context_friend_names(context: Dict[str, Any]) -> List[str]:
    names = []
    for friend in context.get("friends") or []:
        name = (friend.get("name") or "").strip()
        if name:
            names.append(name)
    for contact in context_contacts(context):
        if contact_category(contact) == "friend":
            name = contact_name(contact)
            if name:
                names.append(name)
    return sorted(set(names), key=lambda item: (item.lower(), item))


def tool_results(context: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not context or not isinstance(context, dict):
        return {}
    value = context.get("_tool_results")
    return value if isinstance(value, dict) else {}


def tool_resolved_contact(context: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not context or not isinstance(context, dict):
        return None
    value = context.get("_resolved_contact")
    return value if isinstance(value, dict) else None


def tool_resolved_day_offsets(context: Optional[Dict[str, Any]]) -> List[int]:
    if not context or not isinstance(context, dict):
        return []
    values = context.get("_resolved_day_offsets") or []
    return [value for value in values if isinstance(value, int)]


def tool_resolved_strict_day(context: Optional[Dict[str, Any]]) -> bool:
    if not context or not isinstance(context, dict):
        return False
    return bool(context.get("_resolved_strict_day"))


def tool_resolved_time_preferences(context: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not context or not isinstance(context, dict):
        return {}
    value = context.get("_resolved_time_preferences")
    return value if isinstance(value, dict) else {}


def friend_pseudo_contact_for_text(text: str, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    normalized = normalize_text(text)
    if not normalized:
        return None

    friends = [friend for friend in (context.get("friends") or []) if isinstance(friend, dict) and (friend.get("name") or "").strip()]
    ranked: List[Tuple[float, Dict[str, Any]]] = []
    for friend in friends:
        raw_name = (friend.get("name") or "").strip()
        name_norm = normalize_text(raw_name)
        if not name_norm:
            continue
        score = 0.0
        if name_norm in normalized:
            score += 4.0 + min(len(name_norm), 10) * 0.08
        if contains_any(normalized, FRIEND_TAGS + ["約束", "遊び", "会う", "会える"]):
            score += 0.6
        if score > 0:
            ranked.append((score, friend))

    if not ranked:
        return None

    ranked.sort(key=lambda item: (-item[0], -len((item[1].get("name") or "").strip())))
    top = ranked[0][1]
    return {
        "id": None,
        "display_name": (top.get("name") or "").strip(),
        "relation_type": "friend",
        "timezone": context.get("timezone") or DEFAULT_TZ,
        "preferred_duration_minutes": 90,
        "availability_profiles": [],
        "linked_user_id": top.get("id"),
        "email": top.get("email"),
        "source": "friend_list",
    }


def relevant_contact_for_text(text: str, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    resolved = tool_resolved_contact(context)
    if resolved:
        resolved_category = contact_category(resolved)
        if should_prioritize_work_intent(text, context=context) and resolved_category in {"family", "friend"} and not explicit_social_keyword_signal(text, category=resolved_category):
            resolved = None
        elif resolved_category in {"family", "friend"} and not should_personalize_contact(text, resolved, context=context):
            resolved = None
        else:
            return resolved

    norm = normalize_text(text)
    work_priority = should_prioritize_work_intent(norm, context=context)
    contacts = context_contacts(context)
    if not contacts:
        return None if work_priority else friend_pseudo_contact_for_text(norm, context)

    planned_name = normalize_text(planned_contact_name(context) or "")
    if planned_name:
        exact_match = next((contact for contact in contacts if contact_name_norm(contact) == planned_name), None)
        if exact_match:
            return exact_match
        partial_match = next((contact for contact in contacts if planned_name in contact_name_norm(contact)), None)
        if partial_match:
            return partial_match

    ranked: List[Tuple[float, Dict[str, Any]]] = []
    for contact in contacts:
        category = contact_category(contact)
        name_norm = contact_name_norm(contact)
        relation_hits = []
        for keyword in specific_relation_keywords_for_contact(contact):
            keyword_norm = normalize_text(keyword)
            if keyword_norm and keyword_norm in norm:
                relation_hits.append(keyword_norm)

        has_name_like_match = bool(name_norm and name_norm in norm)
        has_relation_match = bool(relation_hits)
        specific_reference = contact_reference_strength(norm, contact, context=context)
        if category in {"family", "friend"} and specific_reference < 2:
            continue
        if category == "work" and not (has_name_like_match or has_relation_match):
            continue

        score = float(specific_reference)
        if has_name_like_match:
            score += 4.0 + min(len(name_norm), 10) * 0.08
        score += len(relation_hits) * 1.2
        if category == "work" and (has_name_like_match or has_relation_match) and (contains_any(norm, WORK_TAGS) or business_signal_level(norm) > 0):
            score += 0.4
        if work_priority and category in {"family", "friend"}:
            score -= 4.0
        if score > 0:
            ranked.append((score, contact))

    if ranked:
        ranked.sort(key=lambda item: (-item[0], -len(contact_name(item[1]))))
        top_contact = ranked[0][1]
        if work_priority and contact_category(top_contact) in {"family", "friend"}:
            return None
        return top_contact

    if not work_priority:
        pseudo_friend = friend_pseudo_contact_for_text(norm, context)
        if pseudo_friend and should_personalize_contact(text, pseudo_friend, context=context):
            return pseudo_friend

    return None

def extract_named_friend(text: str, context: Dict[str, Any]) -> Optional[str]:
    matched_contact = relevant_contact_for_text(text, context)
    if matched_contact and contact_category(matched_contact) == "friend":
        return contact_name(matched_contact) or None

    norm = normalize_text(text)
    for name in context_friend_names(context):
        name_norm = normalize_text(name)
        if name_norm and name_norm in norm:
            return name
    return None


def relation_tags_from_event(event: Dict[str, Any], context: Optional[Dict[str, Any]] = None) -> List[str]:
    hay = normalize_text(" ".join([*(event.get("group_names") or []), event.get("title") or "", event.get("description") or ""]))
    tags: List[str] = []
    if any(normalize_text(tag) in hay for tag in FAMILY_TAGS):
        tags.append("family")
    if any(normalize_text(tag) in hay for tag in FRIEND_TAGS):
        tags.append("friend")
    if any(normalize_text(tag) in hay for tag in WORK_TAGS):
        tags.append("work")

    if context:
        for contact in context_contacts(context):
            name_norm = contact_name_norm(contact)
            if name_norm and name_norm in hay:
                category = contact_category(contact)
                if category in {"family", "friend", "work"} and category not in tags:
                    tags.append(category)

    return tags or ["group"]


def score_rule(rule: Dict[str, Any], text: str, scope: str, context: Optional[Dict[str, Any]] = None, relevant_contact: Optional[Dict[str, Any]] = None) -> float:
    normalized = normalize_text(text)
    rule_category = rule.get("category")
    work_level = business_signal_level(normalized) if scope == "home" else 0
    family_signal = explicit_social_signal(normalized, context=context, category="family") if scope == "home" else False
    friend_signal = explicit_social_signal(normalized, context=context, category="friend") if scope == "home" else False
    family_keyword_signal = explicit_social_keyword_signal(normalized, category="family") if scope == "home" else False
    friend_keyword_signal = explicit_social_keyword_signal(normalized, category="friend") if scope == "home" else False

    hits = 0.0
    for keyword in rule.get("keywords", []):
        if normalize_text(keyword) in normalized:
            hits += 1.0
    if scope == "group" and rule_category == "work":
        hits += 0.35
    if scope == "home" and rule_category == "work" and work_level > 0:
        hits += 1.4 if work_level >= 2 else 0.65
    if scope == "home" and rule_category == "family":
        if work_level > 0 and not family_keyword_signal:
            return 0.0
        if not family_signal:
            return 0.0
        hits += 0.45
    if scope == "home" and rule_category == "friend":
        if work_level > 0 and not friend_keyword_signal:
            return 0.0
        if not friend_signal:
            return 0.0
        hits += 0.45

    if relevant_contact:
        category = contact_category(relevant_contact)
        if rule_category == category and explicit_contact_signal(normalized, relevant_contact):
            hits += 1.35
        if category == "family" and rule_category == "family" and explicit_contact_signal(normalized, relevant_contact):
            relation_type = (relevant_contact.get("relation_type") or "").strip()
            if relation_type in {"parent", "child", "partner"}:
                hits += 0.35

    if scope == "home":
        if rule_category == "friend" and friend_signal and contains_any(normalized, ["食事", "ご飯", "ごはん", "ランチ", "ディナー"]):
            hits += 0.35
        if rule_category == "family" and family_signal and contains_any(normalized, ["送り迎え", "通院", "付き添い", "食事"]):
            hits += 0.35

    return hits

def detect_ranked_intents(text: str, scope: str, context: Optional[Dict[str, Any]] = None, relevant_contact: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
    normalized = normalize_text(text)
    scored: List[Tuple[float, Dict[str, Any]]] = []
    for rule in INTENT_RULES:
        score = score_rule(rule, normalized, scope, context=context, relevant_contact=relevant_contact)
        if score > 0:
            scored.append((score, rule))

    planned = planned_intent(context)
    if planned:
        planned_rule = next((rule for rule in INTENT_RULES if rule["intent"] == planned), None)
        if planned_rule:
            boost = 8.0 if scope == "home" else 6.0
            if planned_day_offsets(context):
                boost += 0.6
            scored.append((boost, planned_rule))

    if not scored:
        if scope == "home" and business_signal_level(normalized) > 0:
            fallback_intent = "meeting"
        elif scope == "home" and relevant_contact:
            category = contact_category(relevant_contact)
            fallback_intent = "family_plan" if category == "family" else "friend_meetup" if category == "friend" else "alignment"
        else:
            fallback_intent = "follow_up" if scope == "group" else "alignment"
        fallback = next(rule for rule in INTENT_RULES if rule["intent"] == fallback_intent)
        return [dict(fallback, _score=0.1)]

    scored.sort(key=lambda item: (-item[0], item[1]["duration"]))
    uniq: List[Dict[str, Any]] = []
    seen = set()
    for score, rule in scored:
        if rule["intent"] in seen:
            continue
        seen.add(rule["intent"])
        uniq.append(dict(rule, _score=score))
    return uniq[:3]

def target_day_offsets(text: str, now: datetime, context: Optional[Dict[str, Any]] = None) -> List[int]:
    normalized = normalize_text(text)
    base_offsets = list(range(0, 7))

    def prioritize(values: List[int]) -> List[int]:
        seen: List[int] = []
        for val in list(values) + base_offsets:
            if val not in seen:
                seen.append(val)
        return seen

    tool_offsets = tool_resolved_day_offsets(context)
    if tool_offsets:
        return tool_offsets if tool_resolved_strict_day(context) else prioritize(tool_offsets)

    llm_offsets = planned_day_offsets(context)
    if llm_offsets:
        return llm_offsets if planned_strict_day(context) else prioritize(llm_offsets)

    explicit_offsets, explicit_strict = explicit_day_offsets_from_text(normalized, now)
    if explicit_offsets:
        return explicit_offsets if explicit_strict else prioritize(explicit_offsets)

    if "今週末" in normalized or "週末" in normalized or "土日" in normalized:
        weekend = [idx for idx in base_offsets if (now + timedelta(days=idx)).weekday() >= 5]
        return prioritize(weekend)
    if "来週" in normalized:
        weekday = now.weekday()
        next_monday = max(1, 7 - weekday)
        return prioritize(list(range(next_monday, min(next_monday + 5, 7))) + list(range(0, next_monday)))
    return base_offsets


def ruby_weekday(date_obj: date) -> int:
    return (date_obj.weekday() + 1) % 7


TIME_PREFERENCE_MINUTES = {
    "morning": [(9 * 60, 12 * 60)],
    "lunch": [(12 * 60, 13 * 60)],
    "afternoon": [(13 * 60, 18 * 60)],
    "evening": [(17 * 60, 19 * 60 + 30)],
    "after_work": [(18 * 60, 21 * 60 + 30)],
    "night": [(19 * 60, 22 * 60)],
}
TIME_PREFERENCE_SOFT_PADDING_MINUTES = 90


def build_windows_for_day(day: datetime, profile: str) -> List[Tuple[datetime, datetime]]:
    tz = day.tzinfo
    current_date = day.date()
    weekday = current_date.weekday()

    def dt(h: int, m: int = 0) -> datetime:
        return datetime.combine(current_date, time(hour=h, minute=m), tzinfo=tz)

    if profile == "social":
        if weekday < 5:
            return [(dt(18, 0), dt(21, 30))]
        return [(dt(11, 0), dt(20, 0))]

    if profile == "family":
        if weekday < 5:
            return [(dt(17, 30), dt(21, 0))]
        return [(dt(9, 30), dt(18, 30))]

    if weekday >= 5:
        return []
    return [(dt(9, 0), dt(12, 0)), (dt(13, 0), dt(18, 0))]


def _minute_window(day: datetime, start_minute: int, end_minute: int) -> Tuple[datetime, datetime]:
    tz = day.tzinfo
    current_date = day.date()
    return (
        datetime.combine(current_date, time(hour=start_minute // 60, minute=start_minute % 60), tzinfo=tz),
        datetime.combine(current_date, time(hour=end_minute // 60, minute=end_minute % 60), tzinfo=tz),
    )


def _matches_weekday_scope(day: datetime, weekday_scope: Optional[str]) -> bool:
    if weekday_scope == "weekday":
        return day.weekday() < 5
    if weekday_scope == "weekend":
        return day.weekday() >= 5
    return True


def _time_preference_intervals(day: datetime, time_preferences: Dict[str, Any], strict_named_windows: bool = True) -> List[Tuple[datetime, datetime]]:
    if not time_preferences:
        return []
    if not _matches_weekday_scope(day, time_preferences.get("weekday_scope")):
        return []

    not_before = time_preferences.get("not_before_minute")
    not_after = time_preferences.get("not_after_minute")
    named_windows = [value for value in (time_preferences.get("windows") or []) if value in TIME_PREFERENCE_MINUTES]

    minute_ranges: List[Tuple[int, int]] = []
    if named_windows:
        padding = 0 if strict_named_windows else TIME_PREFERENCE_SOFT_PADDING_MINUTES
        for window_name in named_windows:
            for start_minute, end_minute in (TIME_PREFERENCE_MINUTES.get(window_name) or []):
                minute_ranges.append((max(0, start_minute - padding), min(24 * 60, end_minute + padding)))
    elif not_before is not None or not_after is not None:
        minute_ranges.append((0, 24 * 60))
    else:
        return []

    if not minute_ranges:
        return []

    bound_start = max(0, min(24 * 60, safe_int(not_before, 0))) if not_before is not None else 0
    bound_end = max(0, min(24 * 60, safe_int(not_after, 24 * 60))) if not_after is not None else 24 * 60

    intervals: List[Tuple[datetime, datetime]] = []
    for start_minute, end_minute in minute_ranges:
        clipped_start = max(start_minute, bound_start)
        clipped_end = min(end_minute, bound_end)
        if clipped_end <= clipped_start:
            continue
        intervals.append(_minute_window(day, clipped_start, clipped_end))
    return merge_windows(intervals)


def apply_time_preferences_to_windows(windows: List[Tuple[datetime, datetime]], day: datetime, time_preferences: Dict[str, Any], strict_named_windows: bool = True) -> List[Tuple[datetime, datetime]]:
    if not windows:
        return []
    if not time_preferences:
        return windows
    if not _matches_weekday_scope(day, time_preferences.get("weekday_scope")):
        return []

    intervals = _time_preference_intervals(day, time_preferences, strict_named_windows=strict_named_windows)
    if not intervals:
        has_explicit_preference = bool(time_preferences.get("windows") or []) or time_preferences.get("not_before_minute") is not None or time_preferences.get("not_after_minute") is not None
        if strict_named_windows and has_explicit_preference:
            return []
        return windows
    return intersect_windows(windows, intervals)


def time_preference_bonus(start_at: datetime, end_at: datetime, time_preferences: Dict[str, Any]) -> float:
    if not time_preferences:
        return 0.0
    if not _matches_weekday_scope(start_at, time_preferences.get("weekday_scope")):
        return -1.0

    score = 0.0
    named_windows = [value for value in (time_preferences.get("windows") or []) if value in TIME_PREFERENCE_MINUTES]
    if named_windows:
        strict_ranges = _time_preference_intervals(start_at, time_preferences, strict_named_windows=True)
        soft_ranges = _time_preference_intervals(start_at, time_preferences, strict_named_windows=False)
        if any(start_at >= range_start and end_at <= range_end for range_start, range_end in strict_ranges):
            score += 0.7
        elif any(overlaps(start_at, end_at, range_start, range_end) for range_start, range_end in strict_ranges):
            score += 0.15
        elif any(start_at >= range_start and end_at <= range_end for range_start, range_end in soft_ranges):
            score -= 0.15
        elif any(overlaps(start_at, end_at, range_start, range_end) for range_start, range_end in soft_ranges):
            score -= 0.35
        else:
            score -= 1.25

    exact_start_minute = safe_int(time_preferences.get("exact_start_minute"), -1)
    if exact_start_minute >= 0:
        candidate_minute = start_at.hour * 60 + start_at.minute
        distance = abs(candidate_minute - exact_start_minute)
        if distance == 0:
            score += 4.0
        elif distance <= 30:
            score += 2.0
        elif distance <= 60:
            score += 0.9
        elif distance <= 90:
            score += 0.2
        else:
            score -= min(2.0, 0.45 + ((distance - 90) / 30.0) * 0.35)

    return score


def format_clock_label(minute_value: Optional[int]) -> str:
    if minute_value is None:
        return ""
    minute_value = max(0, min(24 * 60 - 1, safe_int(minute_value)))
    return f"{minute_value // 60}:{minute_value % 60:02d}"


def anchored_start_minutes(exact_start_minute: Optional[int]) -> List[int]:
    if exact_start_minute is None:
        return []
    base = safe_int(exact_start_minute, -1)
    if base < 0:
        return []
    offsets = [0, -30, 30, -60, 60, -90, 90, -120, 120]
    values: List[int] = []
    for offset in offsets:
        candidate = base + offset
        if 0 <= candidate < 24 * 60 and candidate not in values:
            values.append(candidate)
    return values


def slot_within_windows(start_at: datetime, end_at: datetime, windows: List[Tuple[datetime, datetime]]) -> bool:
    return any(start_at >= window_start and end_at <= window_end for window_start, window_end in windows)


def expanded_search_offsets(preferred: List[int], now: datetime, profile: str, horizon_days: int = 10) -> List[int]:
    seed = [value for value in preferred if isinstance(value, int) and value >= 0]
    seen: List[int] = []
    for value in seed:
        if value not in seen:
            seen.append(value)

    anchor = min(seen) if seen else 0
    for offset in range(anchor, anchor + max(horizon_days, 1)):
        if offset in seen:
            continue
        candidate_day = now + timedelta(days=offset)
        if profile == "work" and candidate_day.weekday() >= 5:
            continue
        seen.append(offset)
    return seen


def merge_windows(windows: List[Tuple[datetime, datetime]]) -> List[Tuple[datetime, datetime]]:
    cleaned = sorted([(start, end) for start, end in windows if start and end and end > start], key=lambda item: item[0])
    if not cleaned:
        return []
    merged = [cleaned[0]]
    for start, end in cleaned[1:]:
        prev_start, prev_end = merged[-1]
        if start <= prev_end:
            merged[-1] = (prev_start, max(prev_end, end))
        else:
            merged.append((start, end))
    return merged


def intersect_windows(a_windows: List[Tuple[datetime, datetime]], b_windows: List[Tuple[datetime, datetime]]) -> List[Tuple[datetime, datetime]]:
    intersections: List[Tuple[datetime, datetime]] = []
    for a_start, a_end in a_windows:
        for b_start, b_end in b_windows:
            start_at = max(a_start, b_start)
            end_at = min(a_end, b_end)
            if end_at > start_at:
                intersections.append((start_at, end_at))
    return merge_windows(intersections)


def subtract_windows(windows: List[Tuple[datetime, datetime]], blocked: List[Tuple[datetime, datetime]]) -> List[Tuple[datetime, datetime]]:
    segments = list(windows)
    for blocked_start, blocked_end in blocked:
        next_segments: List[Tuple[datetime, datetime]] = []
        for seg_start, seg_end in segments:
            if blocked_end <= seg_start or blocked_start >= seg_end:
                next_segments.append((seg_start, seg_end))
                continue
            if blocked_start > seg_start:
                next_segments.append((seg_start, blocked_start))
            if blocked_end < seg_end:
                next_segments.append((blocked_end, seg_end))
        segments = next_segments
    return merge_windows(segments)


def contact_profile_windows(contact: Optional[Dict[str, Any]], day: datetime, context_tz: ZoneInfo) -> Tuple[List[Tuple[datetime, datetime]], List[Tuple[datetime, datetime]], List[Tuple[datetime, datetime]]]:
    if not contact:
        return [], [], []

    contact_tz = tz_from_name(contact.get("timezone"))
    contact_date = day.astimezone(contact_tz).date()
    weekday_key = ruby_weekday(contact_date)

    preferred: List[Tuple[datetime, datetime]] = []
    available: List[Tuple[datetime, datetime]] = []
    unavailable: List[Tuple[datetime, datetime]] = []

    for profile in contact.get("availability_profiles") or []:
        if safe_int(profile.get("weekday"), -1) != weekday_key:
            continue

        start_minute = max(0, min(24 * 60, safe_int(profile.get("start_minute"))))
        end_minute = max(0, min(24 * 60, safe_int(profile.get("end_minute"))))
        if end_minute <= start_minute:
            continue

        start_dt = datetime.combine(contact_date, time(hour=start_minute // 60, minute=start_minute % 60), tzinfo=contact_tz).astimezone(context_tz)
        end_dt = datetime.combine(contact_date, time(hour=end_minute // 60, minute=end_minute % 60), tzinfo=contact_tz).astimezone(context_tz)
        kind = (profile.get("preference_kind") or "available").strip()

        if kind == "preferred":
            preferred.append((start_dt, end_dt))
        elif kind == "unavailable":
            unavailable.append((start_dt, end_dt))
        else:
            available.append((start_dt, end_dt))

    return merge_windows(preferred), merge_windows(available), merge_windows(unavailable)


def preferred_weekdays_for_contact(contact: Optional[Dict[str, Any]]) -> Tuple[set[int], set[int]]:
    preferred = set()
    available = set()
    if not contact:
        return preferred, available

    for profile in contact.get("availability_profiles") or []:
        weekday = safe_int(profile.get("weekday"), -1)
        kind = (profile.get("preference_kind") or "available").strip()
        if weekday < 0:
            continue
        if kind == "preferred":
            preferred.add(weekday)
        elif kind == "available":
            available.add(weekday)
    return preferred, available


def reorder_offsets_by_contact_availability(offsets: List[int], now: datetime, contact: Optional[Dict[str, Any]], context_tz: ZoneInfo) -> List[int]:
    if not contact:
        return offsets

    preferred_days, available_days = preferred_weekdays_for_contact(contact)
    if not preferred_days and not available_days:
        return offsets

    contact_tz = tz_from_name(contact.get("timezone"))

    def score(offset: int) -> Tuple[int, int]:
        candidate_date = (now + timedelta(days=offset)).astimezone(contact_tz).date()
        weekday_key = ruby_weekday(candidate_date)
        if weekday_key in preferred_days:
            return (0, offset)
        if weekday_key in available_days:
            return (1, offset)
        return (2, offset)

    return sorted(offsets, key=score)


def select_windows_for_day(day: datetime, profile: str, contact: Optional[Dict[str, Any]], context_tz: ZoneInfo, time_preferences: Optional[Dict[str, Any]] = None) -> List[Tuple[datetime, datetime]]:
    base = build_windows_for_day(day, profile)
    preferred, available, unavailable = contact_profile_windows(contact, day, context_tz)
    windows: List[Tuple[datetime, datetime]] = []

    exact_start_minute = safe_int((time_preferences or {}).get("exact_start_minute"), -1)
    if exact_start_minute >= 0:
        windows = list(base)
    else:
        if preferred:
            windows.extend(intersect_windows(base, preferred) or preferred)
        if available:
            windows.extend(intersect_windows(base, available) or available)
        if not windows:
            windows = list(base)

    windows = merge_windows(windows)
    if unavailable:
        windows = subtract_windows(windows, unavailable)
    return merge_windows(windows)


def overlaps(start_a: datetime, end_a: datetime, start_b: datetime, end_b: datetime) -> bool:
    return start_a < end_b and start_b < end_a


def busy_intervals(personal_events: List[Dict[str, Any]], tz: ZoneInfo, buffer_min: int = 15) -> List[Tuple[datetime, datetime]]:
    intervals: List[Tuple[datetime, datetime]] = []
    buffer = timedelta(minutes=buffer_min)
    for event in personal_events:
        start_at = parse_iso(event.get("start_at"), tz)
        end_at = parse_iso(event.get("end_at"), tz)
        if start_at and end_at and end_at > start_at:
            intervals.append((start_at - buffer, end_at + buffer))
    intervals.sort(key=lambda item: item[0])
    return intervals


def contact_slot_bonus(start_at: datetime, end_at: datetime, contact: Optional[Dict[str, Any]], context_tz: ZoneInfo) -> float:
    if not contact:
        return 0.0

    preferred, available, unavailable = contact_profile_windows(contact, start_at, context_tz)
    score = 0.0
    if any(overlaps(start_at, end_at, blocked_start, blocked_end) for blocked_start, blocked_end in unavailable):
        score -= 4.0
    if any(start_at >= pref_start and end_at <= pref_end for pref_start, pref_end in preferred):
        score += 1.3
    elif any(start_at >= avail_start and end_at <= avail_end for avail_start, avail_end in available):
        score += 0.6

    preferred_duration = safe_int(contact.get("preferred_duration_minutes"), 0)
    if preferred_duration > 0:
        actual_duration = int((end_at - start_at).total_seconds() / 60)
        if abs(actual_duration - preferred_duration) <= 15:
            score += 0.35
        elif abs(actual_duration - preferred_duration) <= 30:
            score += 0.15

    return score


def slot_score(start_at: datetime, end_at: datetime, now: datetime, profile: str, preferred_offsets: List[int], base_score: float, contact: Optional[Dict[str, Any]] = None, context_tz: Optional[ZoneInfo] = None, time_preferences: Optional[Dict[str, Any]] = None) -> float:
    score = base_score
    day_offset = (start_at.date() - now.date()).days
    if day_offset in preferred_offsets[:2]:
        score += 0.8
    elif day_offset in preferred_offsets[:4]:
        score += 0.35

    if profile == "work":
        if start_at.weekday() < 5:
            score += 0.5
        if 12 <= start_at.hour < 13:
            score -= 0.6
    elif profile == "social":
        if start_at.weekday() >= 5:
            score += 0.7
        if 18 <= start_at.hour <= 20:
            score += 0.8
    elif profile == "family":
        if start_at.weekday() >= 5:
            score += 0.6
        if 17 <= start_at.hour <= 19:
            score += 0.6

    score -= min(max(day_offset, 0), 6) * 0.05

    if contact and context_tz:
        score += contact_slot_bonus(start_at, end_at, contact, context_tz)
    if time_preferences:
        score += time_preference_bonus(start_at, end_at, time_preferences)

    return score


def find_open_slots(personal_events: List[Dict[str, Any]], duration_min: int, now: datetime, profile: str, text: str, base_score: float, contact: Optional[Dict[str, Any]] = None, limit: int = 3, context: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
    tz = now.tzinfo or ZoneInfo(DEFAULT_TZ)
    busy = busy_intervals(personal_events, tz)
    duration = timedelta(minutes=duration_min)
    search_start = (now + timedelta(minutes=30)).replace(second=0, microsecond=0)
    preferred = target_day_offsets(text, now, context=context)
    preferred = reorder_offsets_by_contact_availability(preferred, now, contact, tz) if contact else preferred
    time_preferences = tool_resolved_time_preferences(context)
    exact_start_minute = time_preferences.get("exact_start_minute") if isinstance(time_preferences, dict) else None

    search_configs = [
        {"offsets": preferred, "strict_named_windows": True, "fallback_mode": None, "score_penalty": 0.0},
    ]

    work_fallback = profile == "work" or should_prioritize_work_intent(text, context=context)
    expanded_offsets = expanded_search_offsets(preferred, now, profile) if work_fallback else preferred
    if work_fallback and expanded_offsets != preferred:
        search_configs.append(
            {"offsets": expanded_offsets, "strict_named_windows": True, "fallback_mode": "broadened_days", "score_penalty": 0.3}
        )
    if work_fallback and time_preferences and (time_preferences.get("windows") or []) and not bool(time_preferences.get("strict_window")):
        search_configs.append(
            {
                "offsets": expanded_offsets,
                "strict_named_windows": False,
                "fallback_mode": "soft_time_window",
                "score_penalty": 0.85,
            }
        )

    candidate_map: Dict[Tuple[str, str], Dict[str, Any]] = {}

    def register_candidate(start_at: datetime, end_at: datetime, fallback_mode: Optional[str], score_penalty: float, time_match: Optional[str] = None) -> None:
        if any(overlaps(start_at, end_at, busy_start, busy_end) for busy_start, busy_end in busy):
            return
        score = slot_score(
            start_at,
            end_at,
            now,
            profile,
            preferred,
            base_score,
            contact=contact,
            context_tz=tz,
            time_preferences=time_preferences,
        )
        score -= float(score_penalty or 0.0)
        candidate = {
            "start_at": iso(start_at),
            "end_at": iso(end_at),
            "score": score,
            "fallback_mode": fallback_mode,
        }
        if time_match:
            candidate["time_match"] = time_match
            if exact_start_minute is not None:
                candidate["time_distance_minute"] = abs((start_at.hour * 60 + start_at.minute) - safe_int(exact_start_minute))
        key = (candidate["start_at"], candidate["end_at"])
        previous = candidate_map.get(key)
        if previous is None or candidate["score"] > previous["score"]:
            candidate_map[key] = candidate

    for config in search_configs:
        for day_offset in config["offsets"]:
            day = search_start + timedelta(days=day_offset)
            base_windows = select_windows_for_day(day, profile, contact, tz)
            windows = apply_time_preferences_to_windows(
                base_windows,
                day,
                time_preferences,
                strict_named_windows=bool(config.get("strict_named_windows", True)),
            )
            _, _, unavailable = contact_profile_windows(contact, day, tz)

            if exact_start_minute is not None and _matches_weekday_scope(day, time_preferences.get("weekday_scope")):
                for anchored_minute in anchored_start_minutes(exact_start_minute):
                    anchored_start, _ = _minute_window(day, anchored_minute, min(anchored_minute + 1, 24 * 60))
                    anchored_end = anchored_start + duration
                    if anchored_start < search_start or anchored_end.date() != anchored_start.date():
                        continue
                    allowed = slot_within_windows(anchored_start, anchored_end, windows) or slot_within_windows(anchored_start, anchored_end, base_windows)
                    if not allowed and any(overlaps(anchored_start, anchored_end, block_start, block_end) for block_start, block_end in unavailable):
                        continue
                    register_candidate(
                        anchored_start,
                        anchored_end,
                        config.get("fallback_mode"),
                        float(config.get("score_penalty") or 0.0),
                        time_match="exact" if anchored_minute == safe_int(exact_start_minute) else "nearby",
                    )

            for window_start, window_end in windows:
                cursor = max(window_start, search_start)
                if cursor.minute % 30 != 0:
                    cursor += timedelta(minutes=(30 - (cursor.minute % 30)))
                    cursor = cursor.replace(second=0, microsecond=0)
                while cursor + duration <= window_end:
                    register_candidate(
                        cursor,
                        cursor + duration,
                        config.get("fallback_mode"),
                        float(config.get("score_penalty") or 0.0),
                    )
                    cursor += timedelta(minutes=30)

    candidates = list(candidate_map.values())

    exact_start_minute = safe_int((time_preferences or {}).get("exact_start_minute"), -1)
    if exact_start_minute >= 0:
        exact_candidates: List[Dict[str, Any]] = []
        near_candidates: List[Dict[str, Any]] = []
        for candidate in candidates:
            start = parse_iso(candidate["start_at"], tz)
            if not start:
                near_candidates.append(candidate)
                continue
            candidate_minute = start.hour * 60 + start.minute
            if candidate_minute == exact_start_minute:
                exact_candidates.append(candidate)
            else:
                near_candidates.append(candidate)
        exact_candidates.sort(key=lambda item: (-item["score"], item["start_at"]))
        near_candidates.sort(key=lambda item: (-item["score"], item["start_at"]))
        candidates = exact_candidates + near_candidates
    else:
        candidates.sort(key=lambda item: (-item["score"], item["start_at"]))
    chosen: List[Dict[str, Any]] = []
    chosen_times: List[datetime] = []
    for candidate in candidates:
        start = parse_iso(candidate["start_at"], tz)
        if any(abs((start - prev).total_seconds()) < 3600 for prev in chosen_times):
            continue
        chosen.append(candidate)
        chosen_times.append(start)
        if len(chosen) >= limit:
            break
    return chosen


def contact_matches_rule(rule: Dict[str, Any], contact: Optional[Dict[str, Any]]) -> bool:
    if not contact:
        return False
    category = contact_category(contact)
    rule_category = (rule.get("category") or "").strip()
    if not rule_category:
        return False
    if category == rule_category:
        return True
    return rule_category == "work" and category not in {"family", "friend"}


def derive_title(rule: Dict[str, Any], user_message: str, context: Dict[str, Any], group_name: Optional[str] = None, contact: Optional[Dict[str, Any]] = None) -> str:
    text = normalize_text(user_message)
    personalize_contact = should_personalize_contact(user_message, contact, context=context)
    contact_display_name = contact_name(contact) if personalize_contact else None
    if not contact_display_name and rule.get("category") == "work":
        contact_display_name = ((tool_results(context).get("social_resolver") or {}).get("resolved_contact_name") or "").strip() or None

    outing_destination = extract_outing_destination(user_message)

    if rule["intent"] == "friend_meetup":
        if outing_destination:
            title = f"{outing_destination}に行く予定"
        elif contact_display_name and ("ご飯" in text or "ごはん" in text or "ランチ" in text or "ディナー" in text or "飲み" in text or "食事" in text):
            title = f"{contact_display_name}と食事"
        elif contact_display_name:
            title = f"{contact_display_name}との予定"
        elif "ランチ" in text:
            title = "友達とランチ"
        elif "ディナー" in text or "飲み" in text or "ご飯" in text or "食事" in text:
            title = "友達と食事"
        else:
            title = rule["title"]
    elif rule["intent"] == "family_plan":
        if outing_destination:
            title = f"{outing_destination}に行く予定"
        elif contact_display_name and ("ご飯" in text or "ごはん" in text or "ランチ" in text or "ディナー" in text or "食事" in text):
            title = f"{contact_display_name}と食事"
        elif contact_display_name and "送り迎え" in text:
            title = f"{contact_display_name}の送り迎え"
        elif contact_display_name and "通院" in text:
            title = f"{contact_display_name}の通院付き添い"
        elif contact_display_name:
            title = f"{contact_display_name}との予定"
        elif "ご飯" in text or "ランチ" in text or "ディナー" in text or "食事" in text:
            title = "家族で食事"
        elif "送り迎え" in text:
            title = "家族の送り迎え"
        elif "通院" in text:
            title = "家族の通院付き添い"
        else:
            title = rule["title"]
    elif contact_display_name and rule.get("category") == "work":
        if rule["intent"] == "review":
            title = f"{contact_display_name}とのレビュー会議"
        elif rule["intent"] == "alignment":
            title = f"{contact_display_name}との調整"
        elif rule["intent"] == "approval":
            title = f"{contact_display_name}との合議"
        elif rule["intent"] == "follow_up":
            title = f"{contact_display_name}との進捗確認"
        else:
            title = f"{contact_display_name}との会議"
    else:
        title = rule["title"]

    if group_name and rule.get("category") == "work":
        return f"{group_name} {title}"
    return title


def compact_reason(text: str) -> str:
    text = (text or "").strip()
    if len(text) <= 80:
        return text
    return text[:77].rstrip() + "..."


def personalized_reason(rule: Dict[str, Any], contact: Optional[Dict[str, Any]] = None, context: Optional[Dict[str, Any]] = None, start_at: Optional[str] = None, end_at: Optional[str] = None) -> str:
    time_preferences = tool_resolved_time_preferences(context)
    exact_start_minute = safe_int(time_preferences.get("exact_start_minute"), -1) if time_preferences else -1
    exact_time_label = (time_preferences.get("exact_time_label") or format_clock_label(exact_start_minute)) if exact_start_minute >= 0 else ""
    start_dt = parse_iso(start_at, local_now(context).tzinfo or ZoneInfo(DEFAULT_TZ)) if start_at else None
    end_dt = parse_iso(end_at, local_now(context).tzinfo or ZoneInfo(DEFAULT_TZ)) if end_at else None

    if exact_start_minute >= 0 and start_dt:
        candidate_minute = start_dt.hour * 60 + start_dt.minute
        if candidate_minute == exact_start_minute:
            return compact_reason(f"{exact_time_label}を優先して候補を出しました。")
        if end_dt:
            end_minute = end_dt.hour * 60 + end_dt.minute
            if candidate_minute <= exact_start_minute <= end_minute:
                return compact_reason(f"{exact_time_label}を含む時間帯で候補を選びました。")
        if abs(candidate_minute - exact_start_minute) <= 90:
            return compact_reason(f"{exact_time_label}に近い時間で候補を選びました。")

    if not contact:
        return rule["reason"]

    name = contact_name(contact)
    category = contact_category(contact)
    if category == "family":
        return compact_reason(f"{name}の空きやすい時間帯も踏まえて候補を選びました。")
    if category == "friend":
        return compact_reason(f"{name}と合わせやすい時間帯を優先して候補を選びました。")
    if category == "work":
        return compact_reason(f"{name}の予定傾向も踏まえて、会議に使いやすい時間帯を優先しました。")
    return rule["reason"]


def build_recommendation(kind: str, title: str, description: str, reason: str, start_at: str, end_at: str, rule: Dict[str, Any], extra_payload: Optional[Dict[str, Any]] = None, source_event_id: Optional[int] = None, rank_position: int = 1) -> Recommendation:
    all_day = bool((extra_payload or {}).get("all_day", False))
    payload = {
        "title": title,
        "description": description,
        "start_at": start_at,
        "end_at": end_at,
        "all_day": all_day,
        "color": rule.get("color") or "#3b82f6",
        "policy_version": POLICY_VERSION,
        "intent": rule.get("intent"),
        "category": rule.get("category"),
        "schedule_profile": rule.get("profile"),
        "rank_position": rank_position,
    }
    if extra_payload:
        payload.update(extra_payload)
    if source_event_id:
        payload["source_event_id"] = source_event_id

    return Recommendation(
        kind=kind,
        title=title,
        description=description,
        reason=compact_reason(reason),
        start_at=start_at,
        end_at=end_at,
        all_day=all_day,
        source_event_id=source_event_id,
        payload=payload,
    )


def diversify_recommendations(recommendations: List[Recommendation], limit: int = 3) -> List[Recommendation]:
    chosen: List[Recommendation] = []
    used_titles: set[str] = set()
    chosen_times: List[datetime] = []
    tz = ZoneInfo(DEFAULT_TZ)

    def norm_title(title: str) -> str:
        return normalize_text(title)

    for rec in recommendations:
        title_key = norm_title(rec.title)
        start = parse_iso(rec.start_at, tz)
        if title_key in used_titles:
            continue
        if start and any(abs((start - prev).total_seconds()) < 3600 for prev in chosen_times):
            continue
        chosen.append(rec)
        used_titles.add(title_key)
        if start:
            chosen_times.append(start)
        if len(chosen) >= limit:
            break
    return chosen


def build_group_recommendations(context: Dict[str, Any], user_message: str) -> List[Recommendation]:
    now = local_now(context)
    personal_events = context.get("personal_events") or []
    group = context.get("group") or {}
    text = combined_group_text(context, user_message)
    rules = detect_ranked_intents(text, scope="group", context=context)[:2]

    candidates: List[Tuple[float, Recommendation]] = []
    for rule in rules:
        slots = find_open_slots(personal_events, duration_min=planned_duration_minutes(context) or rule["duration"], now=now, profile=rule.get("profile", "work"), text=text, base_score=rule.get("_score", 0.0), limit=2, context=context)
        for slot in slots:
            title = derive_title(rule, user_message or text, context, group_name=group.get("name"))
            description = f"AI補助: グループ会話から作成した候補（intent={rule['intent']}）"
            rec = build_recommendation(
                kind="draft_event",
                title=title,
                description=description,
                reason=rule["reason"],
                start_at=slot["start_at"],
                end_at=slot["end_at"],
                rule=rule,
                extra_payload={"score": round(slot["score"], 3)},
            )
            candidates.append((slot["score"], rec))

    ranked = [rec for _, rec in sorted(candidates, key=lambda item: (-item[0], item[1].start_at or ""))]
    ranked = diversify_recommendations(ranked, limit=3)
    for idx, rec in enumerate(ranked, start=1):
        rec.payload["rank_position"] = idx
    return ranked


def sort_copy_candidates(events: List[Dict[str, Any]], user_message: str, context: Dict[str, Any]) -> List[Dict[str, Any]]:
    text = normalize_text(user_message)
    now = local_now(context)
    relevant_contact = relevant_contact_for_text(user_message, context)
    relevant_name = contact_name_norm(relevant_contact)
    relevant_category = contact_category(relevant_contact) if relevant_contact else ""
    work_priority = should_prioritize_work_intent(text, context=context)

    scored: List[Tuple[float, Dict[str, Any]]] = []
    for event in events:
        tags = relation_tags_from_event(event, context)
        hay = normalize_text(" ".join([*(event.get("group_names") or []), event.get("title") or "", event.get("description") or ""]))
        score = 0.0
        if "family" in tags:
            score += 0.8
        if "friend" in tags:
            score += 0.6
        if "work" in tags:
            score += 0.9
        if work_priority and "work" in tags:
            score += 1.4
        if work_priority and ("family" in tags or "friend" in tags) and "work" not in tags:
            score -= 3.0
        if "family" in text and "family" in tags:
            score += 2.0
        if ("友達" in text or "友人" in text) and "friend" in tags:
            score += 2.0
        if relevant_name and relevant_name in hay:
            score += 2.4
        if relevant_category and relevant_category in tags:
            score += 1.8
        if any(normalize_text(name) in text for name in (event.get("group_names") or [])):
            score += 0.5
        start = parse_iso(event.get("start_at"), now.tzinfo)
        if start:
            day_distance = (start.date() - now.date()).days
            score += max(0, 14 - day_distance) * 0.02
        scored.append((score, event))

    scored.sort(key=lambda item: (-item[0], item[1].get("start_at") or ""))
    return [event for _, event in scored]

def build_home_copy_recommendations(context: Dict[str, Any], user_message: str = "") -> List[Recommendation]:
    recommendations: List[Recommendation] = []
    relevant_contact = relevant_contact_for_text(user_message, context)
    relevant_name = contact_name(relevant_contact)
    relevant_category = contact_category(relevant_contact) if relevant_contact else ""
    work_priority = should_prioritize_work_intent(user_message, context=context)

    events = sort_copy_candidates(list(context.get("candidate_group_events") or []), user_message, context)
    for event in events:
        tags = relation_tags_from_event(event, context)
        if work_priority and ("family" in tags or "friend" in tags) and "work" not in tags:
            continue

        idx = len(recommendations) + 1
        if idx > 3:
            break
        group_names = event.get("group_names") or []
        label = group_names[0] if group_names else "所属グループ"
        hay = normalize_text(" ".join(group_names + [event.get("title") or "", event.get("description") or ""]))

        if relevant_name and normalize_text(relevant_name) in hay:
            reason = f"{relevant_name} に関係しそうな近日イベントです。個人予定に先に確保しやすそうです。"
        elif relevant_category == "family" and "family" in tags:
            reason = f"{label} の家族寄りイベントです。家族予定として取り込む候補に向いています。"
        elif relevant_category == "friend" and "friend" in tags:
            reason = f"{label} の友達寄りイベントです。自分の予定として先に確保しやすそうです。"
        elif work_priority and "work" in tags:
            reason = f"{label} の業務寄りイベントです。会議や打ち合わせの候補として取り込みやすそうです。"
        elif "family" in tags:
            reason = f"{label} の家族寄りイベントです。個人予定に取り込む候補として自然です。"
        elif "friend" in tags:
            reason = f"{label} の友達寄りイベントです。自分の予定として先に確保しやすそうです。"
        else:
            reason = f"{label} の近日イベントです。個人予定として取り込む候補に向いています。"

        rule = {
            "intent": "group_event_copy",
            "category": tags[0] if tags else "group",
            "profile": "group",
            "color": event.get("color") or "#3b82f6",
        }
        recommendations.append(
            build_recommendation(
                kind="group_event_copy",
                title=event.get("title") or "イベント候補",
                description=event.get("description") or "AIエージェント提案のコピー候補",
                reason=reason,
                start_at=event.get("start_at"),
                end_at=event.get("end_at"),
                rule=rule,
                source_event_id=event.get("id"),
                rank_position=idx,
                extra_payload={
                    "source_event_id": event.get("id"),
                    "location": event.get("location"),
                    "all_day": bool(event.get("all_day")),
                    "color": event.get("color") or "#3b82f6",
                    "source_group_names": group_names,
                    "relation_tags": tags,
                    "contact_id": relevant_contact.get("id") if relevant_contact else None,
                    "contact_name": relevant_name or None,
                },
            )
        )
    return recommendations

def build_home_draft_recommendations(context: Dict[str, Any], user_message: str) -> List[Recommendation]:
    now = local_now(context)
    personal_events = context.get("personal_events") or []
    text = normalize_text(user_message)
    relevant_contact = relevant_contact_for_text(user_message, context)
    rules = detect_ranked_intents(text, scope="home", context=context, relevant_contact=relevant_contact)[:2]

    candidates: List[Tuple[float, Recommendation]] = []
    for rule in rules:
        active_contact = relevant_contact if contact_matches_rule(rule, relevant_contact) else None
        preferred_duration = safe_int((active_contact or {}).get("preferred_duration_minutes"), 0)
        duration = planned_duration_minutes(context) or (preferred_duration if preferred_duration > 0 else rule["duration"])
        duration = max(30, min(duration, 180))
        base_score = float(rule.get("_score", 0.0)) + (0.4 if active_contact else 0.0)

        slots = find_open_slots(
            personal_events,
            duration_min=duration,
            now=now,
            profile=rule.get("profile", "work"),
            text=user_message,
            base_score=base_score,
            contact=active_contact,
            limit=2,
            context=context,
        )
        for slot in slots:
            personalized_contact = active_contact if should_personalize_contact(user_message, active_contact, context=context) else None
            title = derive_title(rule, user_message, context, contact=personalized_contact)
            description = "AIエージェント提案の予定候補"
            if personalized_contact:
                description = f"AIエージェント提案の予定候補（{contact_name(personalized_contact)}向け）"
            rec = build_recommendation(
                kind="draft_event",
                title=title,
                description=description,
                reason=personalized_reason(rule, personalized_contact, context=context, start_at=slot["start_at"], end_at=slot["end_at"]),
                start_at=slot["start_at"],
                end_at=slot["end_at"],
                rule=rule,
                extra_payload={
                    "score": round(slot["score"], 3),
                    "fallback_mode": slot.get("fallback_mode"),
                    "friend_name": extract_named_friend(user_message, context),
                    "contact_id": personalized_contact.get("id") if personalized_contact else None,
                    "contact_name": contact_name(personalized_contact) if personalized_contact else None,
                    "contact_relation_type": personalized_contact.get("relation_type") if personalized_contact else None,
                },
            )
            candidates.append((slot["score"], rec))

    ranked = [rec for _, rec in sorted(candidates, key=lambda item: (-item[0], item[1].start_at or ""))]
    ranked = diversify_recommendations(ranked, limit=3)
    for idx, rec in enumerate(ranked, start=1):
        rec.payload["rank_position"] = idx
    return ranked


def build_home_recommendations(context: Dict[str, Any], user_message: str) -> List[Recommendation]:
    text = normalize_text(user_message)
    relevant_contact = relevant_contact_for_text(user_message, context)
    wants_draft = bool(relevant_contact) or bool(planned_intent(context)) or bool(planned_day_offsets(context)) or any(normalize_text(keyword) in text for keyword in HOME_TRIGGER_KEYWORDS)

    drafts = build_home_draft_recommendations(context, user_message) if wants_draft else []
    copies = build_home_copy_recommendations(context, user_message)

    if wants_draft and copies:
        merged: List[Recommendation] = []
        merged.extend(drafts[:2])

        if relevant_contact:
            target_category = contact_category(relevant_contact)
            merged.extend(
                [
                    rec
                    for rec in copies
                    if target_category in (rec.payload.get("relation_tags") or [])
                ][:1]
            )
        elif "家族" in text or "友達" in text or "友人" in text:
            target_tag = "family" if "家族" in text else "friend"
            merged.extend([rec for rec in copies if target_tag in (rec.payload.get("relation_tags") or [])][:1])

        if len(merged) < 3:
            merged.extend(copies[: max(0, 3 - len(merged))])

        merged = diversify_recommendations(merged, limit=3)
        for idx, rec in enumerate(merged, start=1):
            rec.payload["rank_position"] = idx
        return merged

    return drafts if drafts else copies


def build_assistant_message(scope: str, recommendations: List[Recommendation], user_message: str, context: Dict[str, Any]) -> str:
    llm_message = planned_assistant_message(context)
    if llm_message:
        return llm_message

    social = (tool_results(context).get("social_resolver") or {}) if context else {}
    calendar = (tool_results(context).get("calendar_summary") or {}) if context else {}
    time_preferences = tool_resolved_time_preferences(context)

    if scope == "group":
        text = combined_group_text(context, user_message)
        top_rule = detect_ranked_intents(text, scope="group", context=context)[0]
        if recommendations:
            labels = " / ".join(dict.fromkeys([rec.title for rec in recommendations]))
            return (
                f"返信案: 「{top_rule['reply']}」\n"
                f"予定候補: {labels} を含む {len(recommendations)} 件を出しました。"
            )
        return f"返信案: 「{top_rule['reply']}」\n今は重ならない候補時間を見つけられませんでした。"

    relevant_contact = relevant_contact_for_text(user_message, context)
    fallback_modes = {((rec.payload or {}).get("fallback_mode") or "") for rec in recommendations if getattr(rec, "payload", None)}
    fallback_modes.discard("")
    if recommendations and fallback_modes and should_prioritize_work_intent(user_message, context=context):
        if "soft_time_window" in fallback_modes:
            return "指定の時間帯にぴったり重ならないため、近い時間帯も含めて会議候補を出しました。"
        return "指定日に空きが薄かったため、近い平日も含めて会議候補を出しました。"

    exact_start_minute = safe_int(time_preferences.get("exact_start_minute"), -1) if time_preferences else -1
    exact_time_label = (time_preferences.get("exact_time_label") or format_clock_label(exact_start_minute)) if exact_start_minute >= 0 else ""
    if recommendations and exact_start_minute >= 0:
        top_start = parse_iso(recommendations[0].start_at, local_now(context).tzinfo or ZoneInfo(DEFAULT_TZ)) if recommendations[0].start_at else None
        if top_start:
            delta = abs((top_start.hour * 60 + top_start.minute) - exact_start_minute)
            if delta <= 15:
                return f"{exact_time_label}を優先して候補を出しました。"
            return f"{exact_time_label}に近い時間も含めて候補を出しました。"

    if recommendations and social.get("resolved_contact_name") and not relevant_contact and not should_prioritize_work_intent(user_message, context=context):
        return f"{social.get('resolved_contact_name')}に合わせやすい候補を出しました。"

    if recommendations and calendar.get("evaluated_days"):
        first_day = (calendar.get("evaluated_days") or [{}])[0]
        if first_day.get("date") and tool_resolved_strict_day(context):
            return f"{first_day.get('date')} を優先して候補を出しました。"

    if recommendations and relevant_contact:
        name = contact_name(relevant_contact)
        category = contact_category(relevant_contact)
        if category == "family":
            return f"{name}の都合を優先しやすい時間帯も踏まえて、候補を出しました。"
        if category == "friend":
            return f"{name}と合わせやすい時間帯を優先して、候補を出しました。"
        if category == "work":
            return f"{name}との予定に使いやすい時間帯も踏まえて、候補を出しました。"

    text = normalize_text(user_message)
    if recommendations and should_prioritize_work_intent(text, context=context):
        return "会議や打ち合わせを入れやすい空き時間を優先して、候補を出しました。"
    if recommendations and any(rec.kind == "group_event_copy" for rec in recommendations) and not user_message.strip():
        return "個人カレンダーに取り込みやすいグループイベント候補を3件まで表示します。"
    if recommendations and ("友達" in text or "友人" in text):
        return "友達との約束を入れやすい時間帯と、関連しそうな候補を出しました。"
    if recommendations and ("家族" in text or "母" in text or "父" in text):
        return "家族の予定を入れやすい時間帯と、関連しそうな候補を出しました。"
    if recommendations:
        return "今の予定の空きに合わせて、追加しやすい候補を出しました。"
    return "今は確度の高い候補が見つかりませんでした。もう少し具体的に相談すると精度が上がります。"


@app.get("/health")
def health() -> Dict[str, Any]:
    llm = current_llm_health()
    provider = POLICY_VERSION
    if llm.get("enabled") and llm.get("ready") and llm.get("backend") and llm.get("model"):
        provider = f"{llm.get('backend')}:{llm.get('model')}"
    return {
        "ok": "true",
        "provider": provider,
        "llm_enabled": str(bool(llm.get("enabled"))).lower(),
        "llm_backend": llm.get("backend") or "",
        "llm_model": llm.get("model") or "",
        "llm_ready": str(bool(llm.get("ready"))).lower(),
        "tool_use_enabled": "true",
        "tool_use_version": TOOL_USE_VERSION,
        "ranker_enabled": "true",
        "ranker_version": RANKER_VERSION,
    }


@app.post("/chat/respond", response_model=ChatResponse)
def chat_respond(request: ChatRequest) -> ChatResponse:
    scope = request.scope
    user_message = (request.user_message or "").strip()
    context = dict(request.context or {})

    if user_message and not request.refresh_only:
        context["_llm_plan"] = plan_message(scope, user_message, context)

    tool_run = run_tools(scope, user_message, context, now=local_now(context))

    if scope == "group":
        recommendations = build_group_recommendations(context, user_message)
    else:
        recommendations = build_home_recommendations(context, user_message)

    recommendations = rerank_recommendations(recommendations, context=context, scope=scope)
    assistant_message = build_assistant_message(scope, recommendations, user_message, context)
    provider = planned_provider(context) or POLICY_VERSION
    return ChatResponse(provider=provider, assistant_message=assistant_message, recommendations=recommendations, tool_invocations=tool_run.get("tool_invocations") or [])
