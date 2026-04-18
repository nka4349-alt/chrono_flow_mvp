from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple
import re
import unicodedata


SOCIAL_HINTS = [
    "友達", "友人", "遊び", "遊ぶ", "遊びに行く", "出かけ", "出掛け", "お出かけ", "おでかけ",
    "旅行", "ドライブ", "会う", "会いたい", "ご飯", "ごはん", "食事", "ランチ", "ディナー", "飲み",
]
HONORIFIC_SUFFIXES = ["さん", "ちゃん", "くん", "君", "氏", "さま", "様"]
ALIAS_SPLIT_RE = re.compile(r"[\s\u3000・･/／_＿\-ー―‐.()（）\[\]{}<>＜＞]+")
ROMAN_CHUNK_RE = re.compile(r"[a-z0-9]{2,24}")
ROMAN_PREFIX_RE = re.compile(r"^([a-z0-9]{2,12})(?=[ぁ-んァ-ヶー一-龠])")
BOUNDARY_SUFFIXES = ["の", "と", "へ", "に", "が", "は", "を", "から", "まで", "との", "さん", "ちゃん", "くん", "氏", "様"]


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "")).strip().lower()


def _strip_honorific(value: str) -> str:
    current = normalize_text(value)
    changed = True
    while changed and current:
        changed = False
        for suffix in HONORIFIC_SUFFIXES:
            suffix_norm = normalize_text(suffix)
            if current.endswith(suffix_norm) and len(current) > len(suffix_norm):
                current = current[: -len(suffix_norm)]
                changed = True
                break
    return current


def _name_variants(name: str, email: Optional[str] = None) -> List[str]:
    normalized = normalize_text(name)
    variants = {normalized, normalized.replace(" ", "").replace("\u3000", "")}

    for value in list(variants):
        stripped = _strip_honorific(value)
        if stripped:
            variants.add(stripped)

        for token in ALIAS_SPLIT_RE.split(value):
            token_norm = _strip_honorific(token)
            if token_norm:
                variants.add(token_norm)
                if len(token_norm) >= 3:
                    variants.add(token_norm[:3])

        compact = value.replace(" ", "").replace("\u3000", "")
        prefix_match = ROMAN_PREFIX_RE.match(compact)
        if prefix_match:
            variants.add(prefix_match.group(1))
        for chunk in ROMAN_CHUNK_RE.findall(compact):
            variants.add(chunk)

    local_part = normalize_text((email or "").split("@", 1)[0])
    if local_part:
        variants.add(local_part)
        for token in re.split(r"[._\-]+", local_part):
            if token:
                variants.add(token)

    filtered: List[str] = []
    seen = set()
    for value in variants:
        compact = value.strip()
        if not compact:
            continue
        if len(compact) < 2:
            continue
        if compact in seen:
            continue
        seen.add(compact)
        filtered.append(compact)
    return sorted(filtered, key=lambda item: (-len(item), item))


def _alias_hit_score(text: str, alias: str) -> float:
    alias_norm = normalize_text(alias)
    if not alias_norm or alias_norm not in text:
        return 0.0

    score = 1.0 + min(len(alias_norm), 12) * 0.05
    if any(f"{alias_norm}{suffix}" in text for suffix in BOUNDARY_SUFFIXES):
        score += 0.75
    return score


def _alias_overlap_score(planned_name: str, aliases: List[str]) -> float:
    planned_norm = normalize_text(planned_name)
    if not planned_norm:
        return 0.0

    best = 0.0
    for alias in aliases:
        alias_norm = normalize_text(alias)
        if not alias_norm:
            continue
        if alias_norm == planned_norm:
            best = max(best, 3.0)
        elif alias_norm in planned_norm or planned_norm in alias_norm:
            best = max(best, 2.0 + min(len(alias_norm), 8) * 0.04)
    return best


def _best_alias_match(text: str, planned_name: str, aliases: List[str]) -> Tuple[float, Optional[str]]:
    best_score = _alias_overlap_score(planned_name, aliases)
    best_alias = None
    for alias in aliases:
        hit_score = _alias_hit_score(text, alias)
        if hit_score > best_score:
            best_score = hit_score
            best_alias = alias
    return best_score, best_alias


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
    for message in reversed(context.get("recent_direct_messages") or []):
        if not isinstance(message, dict):
            continue
        peer_name = (message.get("peer_name") or "").strip()
        peer_id = message.get("peer_id")
        key = (peer_id, peer_name)
        if not peer_name or key in seen:
            continue
        seen.add(key)
        peers.append(
            {
                "id": peer_id,
                "name": peer_name,
                "email": message.get("peer_email"),
                "source": "recent_direct_messages",
                "last_message_at": message.get("created_at"),
            }
        )
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


def _contact_aliases(contact: Dict[str, Any]) -> List[str]:
    return _name_variants(
        contact.get("display_name") or contact.get("linked_user_name") or "",
        email=contact.get("email") or contact.get("linked_user_email"),
    )


def _friend_aliases(friend: Dict[str, Any]) -> List[str]:
    return _name_variants(friend.get("name") or friend.get("display_name") or "", email=friend.get("email"))


def _peer_aliases(peer: Dict[str, Any]) -> List[str]:
    return _name_variants(peer.get("name") or "", email=peer.get("email"))


def _relation_type_of_resolved_contact(contact: Optional[Dict[str, Any]]) -> str:
    return ((contact or {}).get("relation_type") or "").strip()


def resolve_entities(text: str, context: Dict[str, Any], planned_contact_name: Optional[str] = None) -> Dict[str, Any]:
    normalized = normalize_text(text)
    planned_name = normalize_text(planned_contact_name or "")

    best_contact: Tuple[float, Optional[Dict[str, Any]], Optional[str]] = (0.0, None, None)
    best_friend: Tuple[float, Optional[Dict[str, Any]], Optional[str]] = (0.0, None, None)
    best_peer: Tuple[float, Optional[Dict[str, Any]], Optional[str]] = (0.0, None, None)

    for contact in _contact_rows(context):
        name = (contact.get("display_name") or "").strip()
        if not name:
            continue
        score, alias = _best_alias_match(normalized, planned_name, _contact_aliases(contact))
        if score > best_contact[0]:
            best_contact = (score, contact, alias)

    for friend in _friend_rows(context):
        name = (friend.get("name") or friend.get("display_name") or "").strip()
        if not name:
            continue
        score, alias = _best_alias_match(normalized, planned_name, _friend_aliases(friend))
        score += 0.18
        if score > best_friend[0]:
            best_friend = (score, friend, alias)

    for peer in _recent_dm_peer_rows(context):
        name = (peer.get("name") or "").strip()
        if not name:
            continue
        score, alias = _best_alias_match(normalized, planned_name, _peer_aliases(peer))
        if peer.get("last_message_at"):
            score += 0.24
        if score > best_peer[0]:
            best_peer = (score, peer, alias)

    resolved_contact = best_contact[1] if best_contact[0] >= 1.0 else None
    resolved_friend = None
    resolved_peer = None
    matched_from = None
    matched_alias = best_contact[2] if resolved_contact else None
    if resolved_contact is not None:
        matched_from = "contacts"
    else:
        resolved_friend = best_friend[1] if best_friend[0] >= 1.0 else None
        if resolved_friend is not None:
            resolved_contact = _make_pseudo_contact(resolved_friend, relation_type="friend", source="friend_list")
            matched_from = "friends"
            matched_alias = best_friend[2]
        else:
            resolved_peer = best_peer[1] if best_peer[0] >= 1.0 else None
            if resolved_peer is not None:
                resolved_contact = _make_pseudo_contact(resolved_peer, relation_type="friend", source="recent_direct_messages")
                matched_from = "recent_direct_messages"
                matched_alias = best_peer[2]

    resolved_relation_type = _relation_type_of_resolved_contact(resolved_contact)
    social_signal = any(token in normalized for token in [normalize_text(value) for value in SOCIAL_HINTS])
    social_signal = social_signal or resolved_relation_type in {"friend", "family", "parent", "child", "partner"}

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
        "resolved_relation_type": resolved_relation_type or None,
        "matched_from": matched_from,
        "matched_alias": matched_alias,
        "social_signal": social_signal,
        "friend_candidates": friend_candidates[:16],
    }
