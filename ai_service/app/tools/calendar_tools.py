from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple
import re
import unicodedata


WINDOW_KEYWORDS = {
    "morning": ["午前", "朝", "朝イチ", "朝一", "朝早め", "午前中"],
    "lunch": ["昼", "お昼", "ランチ", "昼休み", "正午"],
    "afternoon": ["午後", "午後帯", "昼過ぎ"],
    "evening": ["夕方"],
    "after_work": ["仕事終わり", "退勤後", "終業後", "仕事後", "仕事終わりに"],
    "night": ["夜", "今晩", "今夜", "ディナー"],
}
TIME_RANGE_RE = re.compile(r"(?P<start>\d{1,2})時(?P<start_half>半)?\s*(?:-|〜|~|から)\s*(?P<end>\d{1,2})時(?P<end_half>半)?")
TIME_AFTER_RE = re.compile(r"(?P<hour>\d{1,2})時(?P<half>半)?\s*(?:以降|から)")
TIME_BEFORE_RE = re.compile(r"(?P<hour>\d{1,2})時(?P<half>半)?\s*(?:まで)")
EXACT_TIME_JP_RE = re.compile(r"(?P<hour>\d{1,2})時(?:(?P<minute>\d{1,2})分?|(?P<half>半))?(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
EXACT_TIME_COLON_RE = re.compile(r"(?P<hour>\d{1,2})[:：](?P<minute>\d{2})(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
EXACT_TIME_COMPACT_RE = re.compile(r"(?<!\d)(?P<hour>[01]?\d|2[0-3])(?P<minute>[0-5]\d)(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
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


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "")).strip().lower()


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


def _next_week_range(now: datetime) -> List[int]:
    weekday = now.weekday()
    first = 7 - weekday
    return list(range(max(first, 1), max(first, 1) + 7))


def explicit_day_offsets_from_text(text: str, now: datetime) -> Tuple[List[int], bool]:
    normalized = normalize_text(text)
    if not normalized:
        return [], False

    if "明々後日" in normalized or "しあさって" in normalized:
        return [3], True
    if "明後日" in normalized or "あさって" in normalized:
        return [2], True
    if "明日" in normalized or "あした" in normalized:
        return [1], True
    if "今日" in normalized or "きょう" in normalized:
        return [0], True

    if "今週中" in normalized:
        return [offset for offset in range(0, 7) if (now + timedelta(days=offset)).weekday() < 5][:5], False
    if "平日" in normalized:
        return [offset for offset in range(0, 14) if (now + timedelta(days=offset)).weekday() < 5][:7], False
    if "来週前半" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() <= 2][:4], True
    if "来週後半" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() >= 3][:4], True
    if "週明け" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() <= 1][:3], True
    if "来週末" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() >= 5][:2], True
    if "今週末" in normalized or "週末" in normalized or "土日" in normalized:
        offsets = [offset for offset in range(0, 14) if (now + timedelta(days=offset)).weekday() >= 5]
        return offsets[:4] or [5], True
    if "来週" in normalized:
        return [offset for offset in _next_week_range(now) if (now + timedelta(days=offset)).weekday() < 5][:5], False

    matched_weekday = None
    for token, weekday in WEEKDAY_MAP.items():
        if token in normalized:
            matched_weekday = weekday
            break

    if matched_weekday is None:
        return [], False

    current_weekday = now.weekday()
    if "再来週" in normalized:
        base = (7 - current_weekday) + 7
        return [base + matched_weekday], True
    if "来週" in normalized:
        base = 7 - current_weekday
        return [base + matched_weekday], True

    delta = (matched_weekday - current_weekday) % 7
    return [delta], True


def extract_date_constraints(now: datetime, user_message: str, planned_day_offsets: List[int], planned_strict_day: bool) -> Dict[str, Any]:
    offsets: List[int] = []
    for value in planned_day_offsets or []:
        try:
            offset = int(value)
        except Exception:
            continue
        if 0 <= offset <= 21 and offset not in offsets:
            offsets.append(offset)

    explicit_offsets, explicit_strict = explicit_day_offsets_from_text(user_message, now)
    if not offsets and explicit_offsets:
        offsets = explicit_offsets

    target_dates = [
        (now + timedelta(days=offset)).date().isoformat()
        for offset in offsets[:7]
    ]

    return {
        "day_offsets": offsets[:7],
        "strict_day": bool(planned_strict_day or explicit_strict),
        "target_dates": target_dates,
    }


def _minute_from_match(hour: str, half: Optional[str]) -> int:
    value = max(0, min(23, int(hour))) * 60
    if half:
        value += 30
    return value


def _exact_minute(hour: str, minute: Optional[str] = None, half: Optional[str] = None) -> int:
    value = max(0, min(23, int(hour))) * 60
    if minute is not None and minute != "":
        value += max(0, min(59, int(minute)))
    elif half:
        value += 30
    return value


def _format_minute_label(minute_value: int) -> str:
    hour = max(0, min(23, minute_value // 60))
    minute = max(0, min(59, minute_value % 60))
    return f"{hour}:{minute:02d}"


def _extract_exact_time(normalized: str) -> Tuple[Optional[int], Optional[str]]:
    if not normalized:
        return None, None

    for pattern in (EXACT_TIME_COLON_RE, EXACT_TIME_JP_RE, EXACT_TIME_COMPACT_RE):
        match = pattern.search(normalized)
        if not match:
            continue
        minute_value = _exact_minute(match.group("hour"), match.groupdict().get("minute"), match.groupdict().get("half"))
        return minute_value, _format_minute_label(minute_value)

    if "正午" in normalized:
        return 12 * 60, "12:00"
    return None, None


def extract_time_preferences(text: str) -> Dict[str, Any]:
    normalized = normalize_text(text)
    windows: List[str] = []
    labels: List[str] = []
    weekday_scope: Optional[str] = None
    not_before: Optional[int] = None
    not_after: Optional[int] = None
    strict_window = False
    exact_start_minute: Optional[int] = None
    exact_time_label: Optional[str] = None

    if not normalized:
        return {
            "windows": [],
            "labels": [],
            "weekday_scope": None,
            "not_before_minute": None,
            "not_after_minute": None,
            "strict_window": False,
            "exact_start_minute": None,
            "exact_time_label": None,
        }

    if "平日" in normalized:
        weekday_scope = "weekday"
        labels.append("平日")
    elif any(token in normalized for token in ["来週末", "今週末", "週末", "土日"]):
        weekday_scope = "weekend"
        labels.append("週末")

    for window_name, keywords in WINDOW_KEYWORDS.items():
        if any(keyword in normalized for keyword in keywords):
            windows.append(window_name)
            labels.append(keywords[0])

    range_match = TIME_RANGE_RE.search(normalized)
    if range_match:
        not_before = _minute_from_match(range_match.group("start"), range_match.group("start_half"))
        not_after = _minute_from_match(range_match.group("end"), range_match.group("end_half"))
        strict_window = True
        labels.append(f"{range_match.group('start')}時{'半' if range_match.group('start_half') else ''}-{range_match.group('end')}時{'半' if range_match.group('end_half') else ''}")
    else:
        after_match = TIME_AFTER_RE.search(normalized)
        if after_match:
            not_before = _minute_from_match(after_match.group("hour"), after_match.group("half"))
            strict_window = True
            labels.append(f"{after_match.group('hour')}時{'半' if after_match.group('half') else ''}以降")
        before_match = TIME_BEFORE_RE.search(normalized)
        if before_match:
            not_after = _minute_from_match(before_match.group("hour"), before_match.group("half"))
            strict_window = True
            labels.append(f"{before_match.group('hour')}時{'半' if before_match.group('half') else ''}まで")

    if not strict_window:
        exact_start_minute, exact_time_label = _extract_exact_time(normalized)
        if exact_start_minute is not None and exact_time_label:
            labels.append(f"{exact_time_label}ごろ")

    seen: List[str] = []
    dedup_windows: List[str] = []
    for value in windows:
        if value not in seen:
            seen.append(value)
            dedup_windows.append(value)

    dedup_labels: List[str] = []
    for label in labels:
        if label and label not in dedup_labels:
            dedup_labels.append(label)

    return {
        "windows": dedup_windows,
        "labels": dedup_labels,
        "weekday_scope": weekday_scope,
        "not_before_minute": not_before,
        "not_after_minute": not_after,
        "strict_window": strict_window,
        "exact_start_minute": exact_start_minute,
        "exact_time_label": exact_time_label,
    }


def summarize_calendar(context: Dict[str, Any], now: datetime, day_offsets: List[int], strict_day: bool, limit_days: int = 4) -> Dict[str, Any]:
    events = [event for event in (context.get("personal_events") or []) if isinstance(event, dict)]
    normalized_offsets = []
    for value in day_offsets or []:
        try:
            offset = int(value)
        except Exception:
            continue
        if 0 <= offset <= 21 and offset not in normalized_offsets:
            normalized_offsets.append(offset)

    if not normalized_offsets:
        normalized_offsets = list(range(0, limit_days))

    days: List[Dict[str, Any]] = []
    for offset in normalized_offsets[:limit_days]:
        day_start = (now + timedelta(days=offset)).replace(hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)
        busy_minutes = 0
        matches: List[Dict[str, Any]] = []
        for event in events:
            start_at = _parse_iso(event.get("start_at"))
            end_at = _parse_iso(event.get("end_at"))
            if not start_at or not end_at:
                continue
            if end_at <= day_start or start_at >= day_end:
                continue
            clipped_start = max(start_at, day_start)
            clipped_end = min(end_at, day_end)
            busy_minutes += max(0, int((clipped_end - clipped_start).total_seconds() // 60))
            matches.append(
                {
                    "title": event.get("title"),
                    "start_at": start_at.isoformat(),
                    "end_at": end_at.isoformat(),
                    "all_day": bool(event.get("all_day")),
                }
            )

        days.append(
            {
                "offset": offset,
                "date": day_start.date().isoformat(),
                "event_count": len(matches),
                "busy_minutes": busy_minutes,
                "events": matches[:6],
            }
        )

    total_busy = sum(_safe_int(day.get("busy_minutes")) for day in days)
    return {
        "strict_day": bool(strict_day),
        "evaluated_days": days,
        "total_busy_minutes": total_busy,
    }
