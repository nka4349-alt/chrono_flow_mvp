from __future__ import annotations

from typing import Any, Dict, List, Optional
import unicodedata


SOCIAL_HINTS = [
    "友達", "友人", "遊び", "遊ぶ", "遊びに行く", "出かけ", "出掛け", "お出かけ", "おでかけ",
    "旅行", "ドライブ", "会う", "会いたい", "ご飯", "ごはん", "食事", "ランチ", "ディナー", "飲み",
]
HONORIFIC_SUFFIXES = ["さん", "ちゃん", "くん", "君", "氏", "さま", "様"]


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "")).strip().lower()


def _name_variants(name: str) -> List[str]:
    normalized = normalize_text(name)
    variants = {normalized, normalized.replace(" ", "")}
    for suffix in HONORIFIC_SUFFIXES:
        suffix_norm = normalize_text(suffix)
        for value in list(variants):
            if value.endswith(suffix_norm) and len(value) > len(suffix_norm):
                variants.add(value[: -len(suffix_norm)])
    return [value for value in variants if value]


def _contact_rows(context: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for contact in context.get("contacts") or []:
        if isinstance(contact, dict) and (contact.get("display_name") or "").strip():
            rows.append(contact)
    return rows


def _friend_rows(context: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for friend in context.get("friends") or []:
        if isinstance(friend, dict) and (friend.get("name") or friend.get("display_name") or "").strip():
            rows.append(friend)
    return rows


def _recent_dm_peer_rows(context: Dict[str, Any]) -> List[Dict[str, Any]]:
    peers: List[Dict[str, Any]] = []
    seen = set()
    for message in context.get("recent_direct_messages") or []:
        if not isinstance(message, dict):
            continue
        peer_name = (message.get("peer_name") or "").strip()
        peer_id = message.get("peer_id")
        key = (peer_id, peer_name)
        if not peer_name or key in seen:
            continue
        seen.add(key)
        peers.append({"id": peer_id, "name": peer_name, "source": "recent_direct_messages"})
    return peers


def _make_pseudo_contact(entity: Dict[str, Any], relation_type: str = "friend", source: str = "friend_list") -> Dict[str, Any]:
    display_name = (entity.get("name") or entity.get("display_name") or "").strip()
    return {
        "id": entity.get("id"),
        "display_name": display_name,
        "relation_type": relation_type,
        "timezone": entity.get("timezone") or "Asia/Tokyo",
        "preferred_duration_minutes": 90,
        "availability_profiles": [],
        "linked_user_id": entity.get("id"),
        "email": entity.get("email"),
        "source": source,
    }


def _matches_name(text: str, name: str) -> bool:
    if not name:
        return False
    variants = _name_variants(name)
    return any(variant and variant in text for variant in variants)


def _planned_matches_name(planned_name: str, name: str) -> bool:
    if not planned_name or not name:
        return False
    plan_variants = set(_name_variants(planned_name))
    name_variants = set(_name_variants(name))
    return bool(plan_variants & name_variants)


def resolve_entities(text: str, context: Dict[str, Any], planned_contact_name: Optional[str] = None) -> Dict[str, Any]:
    normalized = normalize_text(text)
    planned_name = normalize_text(planned_contact_name or "")

    exact_contact = None
    partial_contact = None
    exact_friend = None
    partial_friend = None
    exact_peer = None
    partial_peer = None

    for contact in _contact_rows(context):
        name = (contact.get("display_name") or "").strip()
        if not name:
            continue
        if planned_name and _planned_matches_name(planned_name, name):
            exact_contact = contact
            break
        if _matches_name(normalized, name):
            exact_contact = contact
            break
        if planned_name and any(variant in normalize_text(name) for variant in _name_variants(planned_name)) and partial_contact is None:
            partial_contact = contact

    if exact_contact is None:
        for friend in _friend_rows(context):
            name = (friend.get("name") or friend.get("display_name") or "").strip()
            if not name:
                continue
            if planned_name and _planned_matches_name(planned_name, name):
                exact_friend = friend
                break
            if _matches_name(normalized, name):
                exact_friend = friend
                break
            if planned_name and any(variant in normalize_text(name) for variant in _name_variants(planned_name)) and partial_friend is None:
                partial_friend = friend

    if exact_contact is None and exact_friend is None:
        for peer in _recent_dm_peer_rows(context):
            name = (peer.get("name") or "").strip()
            if not name:
                continue
            if planned_name and _planned_matches_name(planned_name, name):
                exact_peer = peer
                break
            if _matches_name(normalized, name):
                exact_peer = peer
                break
            if planned_name and any(variant in normalize_text(name) for variant in _name_variants(planned_name)) and partial_peer is None:
                partial_peer = peer

    resolved_contact = exact_contact or partial_contact
    resolved_friend = None
    resolved_peer = None
    matched_from = None
    if resolved_contact is not None:
        matched_from = "contacts"
    else:
        resolved_friend = exact_friend or partial_friend
        if resolved_friend is not None:
            resolved_contact = _make_pseudo_contact(resolved_friend, relation_type="friend", source="friend_list")
            matched_from = "friends"
        else:
            resolved_peer = exact_peer or partial_peer
            if resolved_peer is not None:
                resolved_contact = _make_pseudo_contact(resolved_peer, relation_type="friend", source="recent_direct_messages")
                matched_from = "recent_direct_messages"

    social_signal = any(token in normalized for token in [normalize_text(value) for value in SOCIAL_HINTS])

    friend_candidates = []
    for friend in _friend_rows(context):
        name = (friend.get("name") or friend.get("display_name") or "").strip()
        if name and name not in friend_candidates:
            friend_candidates.append(name)
    for peer in _recent_dm_peer_rows(context):
        name = (peer.get("name") or "").strip()
        if name and name not in friend_candidates:
            friend_candidates.append(name)

    return {
        "resolved_contact": resolved_contact,
        "resolved_contact_name": (resolved_contact or {}).get("display_name") if resolved_contact else None,
        "matched_from": matched_from,
        "social_signal": social_signal or bool(resolved_contact),
        "friend_candidates": friend_candidates[:16],
    }
