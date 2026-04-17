from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

RANKER_VERSION = "contextual-bandit-v1"

FEATURE_WEIGHTS = {
    "category": 0.42,
    "intent": 0.34,
    "schedule_profile": 0.22,
    "hour_bucket": 0.30,
    "weekday": 0.18,
    "duration_bucket": 0.16,
    "contact_relation_type": 0.26,
    "kind": 0.10,
}


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return default


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None


def _hour_bucket(hour_value: Any) -> Optional[str]:
    try:
        hour = int(hour_value)
    except Exception:
        return None

    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 15:
        return "midday"
    if 15 <= hour < 18:
        return "afternoon"
    if 18 <= hour < 22:
        return "evening"
    return "night"


def _duration_bucket(value: Any) -> Optional[str]:
    try:
        minutes = int(value)
    except Exception:
        return None

    if minutes <= 0:
        return None
    if minutes < 45:
        return "short"
    if minutes <= 90:
        return "medium"
    return "long"


def _ruby_weekday(dt: Optional[datetime]) -> Optional[str]:
    if not dt:
        return None
    return str((dt.weekday() + 1) % 7)


def _history(context: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not isinstance(context, dict):
        return {}
    value = context.get("ranking_history")
    return value if isinstance(value, dict) else {}


def _candidate_features(recommendation: Any) -> Dict[str, str]:
    payload = getattr(recommendation, "payload", {}) or {}
    start_at = _parse_iso(getattr(recommendation, "start_at", None))
    end_at = _parse_iso(getattr(recommendation, "end_at", None))
    duration_minutes = None
    if start_at and end_at:
        duration_minutes = max(1, int((end_at - start_at).total_seconds() // 60))
    if duration_minutes is None:
        duration_minutes = payload.get("duration_minutes")

    return {
        key: value
        for key, value in {
            "kind": str(getattr(recommendation, "kind", "") or "").strip() or None,
            "category": str(payload.get("category") or "").strip() or None,
            "intent": str(payload.get("intent") or "").strip() or None,
            "schedule_profile": str(payload.get("schedule_profile") or "").strip() or None,
            "weekday": _ruby_weekday(start_at),
            "hour_bucket": _hour_bucket(start_at.hour if start_at else payload.get("start_hour")),
            "duration_bucket": _duration_bucket(duration_minutes),
            "contact_relation_type": str(payload.get("contact_relation_type") or "").strip() or None,
        }.items()
        if value not in (None, "")
    }


def _feature_contribution(feature_name: str, feature_value: str, history: Dict[str, Any]) -> Tuple[float, Optional[Dict[str, Any]]]:
    feature_stats = (((history.get("feature_stats") or {}).get(feature_name) or {}))
    stats = feature_stats.get(feature_value)
    if not isinstance(stats, dict):
        return 0.0, None

    shown = _safe_float(stats.get("shown_count"), 0.0)
    interacted = _safe_float(stats.get("interacted_count"), 0.0)
    reward_sum = _safe_float(stats.get("reward_sum"), 0.0)
    if shown <= 0 or interacted <= 0:
        return 0.0, None

    mean_reward = reward_sum / max(1.0, interacted)
    confidence = min(1.0, interacted / 6.0) * min(1.0, shown / 10.0)
    contribution = FEATURE_WEIGHTS.get(feature_name, 0.0) * mean_reward * confidence
    contribution = max(-0.8, min(0.9, contribution))

    return contribution, {
        "feature": feature_name,
        "value": feature_value,
        "shown_count": int(shown),
        "interacted_count": int(interacted),
        "reward_sum": round(reward_sum, 4),
        "mean_reward": round(mean_reward, 4),
        "confidence": round(confidence, 4),
        "contribution": round(contribution, 4),
    }


def rerank_recommendations(recommendations: List[Any], context: Optional[Dict[str, Any]] = None, scope: str = "home") -> List[Any]:
    if not recommendations:
        return recommendations

    history = _history(context)
    sample_size = int(history.get("sample_size") or 0)
    interacted_size = int(history.get("interacted_size") or 0)
    if sample_size <= 0 or interacted_size <= 0:
        return recommendations

    global_strength = min(1.0, interacted_size / 12.0)
    if scope == "group":
        global_strength *= 0.85

    ranked: List[Tuple[float, str, Any]] = []
    for recommendation in recommendations:
        payload = getattr(recommendation, "payload", {}) or {}
        base_score = _safe_float(payload.get("score"), 0.0)
        contributions: List[Dict[str, Any]] = []
        raw_bonus = 0.0
        for feature_name, feature_value in _candidate_features(recommendation).items():
            value_bonus, debug = _feature_contribution(feature_name, str(feature_value), history)
            if debug is not None:
                raw_bonus += value_bonus
                contributions.append(debug)

        bonus = max(-1.0, min(1.4, raw_bonus * global_strength))
        final_score = base_score + bonus

        payload["ranker"] = {
            "version": RANKER_VERSION,
            "base_score": round(base_score, 4),
            "bonus": round(bonus, 4),
            "final_score": round(final_score, 4),
            "sample_size": sample_size,
            "interacted_size": interacted_size,
            "global_strength": round(global_strength, 4),
            "contributions": contributions[:6],
        }
        recommendation.payload = payload
        ranked.append((final_score, getattr(recommendation, "start_at", "") or "", recommendation))

    reranked = [item[2] for item in sorted(ranked, key=lambda item: (-item[0], item[1]))]
    for idx, recommendation in enumerate(reranked, start=1):
        payload = getattr(recommendation, "payload", {}) or {}
        payload["rank_position"] = idx
        recommendation.payload = payload
    return reranked
