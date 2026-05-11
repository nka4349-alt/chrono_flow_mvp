from __future__ import annotations

from datetime import datetime, timedelta, date
from typing import Any, Dict, List, Optional, Tuple
import re
import unicodedata


WINDOW_KEYWORDS = {
    "morning": ["午前", "朝", "朝イチ", "朝一", "朝早め", "午前中"],
    "lunch": ["昼", "お昼", "ランチ", "昼休み", "正午"],
    "afternoon": ["午後", "午後帯", "昼過ぎ"],
    "evening": ["夕方", "放課後"],
    "after_work": ["仕事終わり", "退勤後", "終業後", "仕事後", "仕事終わりに"],
    "night": ["夜", "今晩", "今夜", "ディナー"],
}
TIME_RANGE_RE = re.compile(r"(?P<start>\d{1,2})時(?P<start_half>半)?\s*(?:-|〜|~|から)\s*(?P<end>\d{1,2})時(?P<end_half>半)?")
TIME_AFTER_RE = re.compile(r"(?P<hour>\d{1,2})時(?P<half>半)?\s*(?:以降|から)")
TIME_BEFORE_RE = re.compile(r"(?P<hour>\d{1,2})時(?P<half>半)?\s*(?:まで)")
TIME_RANGE_COLON_RE = re.compile(r"(?P<start_hour>\d{1,2})[:：](?P<start_minute>\d{2})\s*(?:-|〜|~|から)\s*(?P<end_hour>\d{1,2})[:：](?P<end_minute>\d{2})")
TIME_RANGE_JP_DETAIL_RE = re.compile(r"(?P<start_hour>\d{1,2})時(?:(?P<start_minute>\d{1,2})分?|(?P<start_half>半))?\s*(?:-|〜|~|から)\s*(?P<end_hour>\d{1,2})時(?:(?P<end_minute>\d{1,2})分?|(?P<end_half>半))?")
TIME_AFTER_COLON_RE = re.compile(r"(?P<hour>\d{1,2})[:：](?P<minute>\d{2})\s*(?:以降|から)")
TIME_BEFORE_COLON_RE = re.compile(r"(?P<hour>\d{1,2})[:：](?P<minute>\d{2})\s*(?:まで)")
TIME_AFTER_JP_DETAIL_RE = re.compile(r"(?P<hour>\d{1,2})時(?:(?P<minute>\d{1,2})分?|(?P<half>半))?\s*(?:以降|から)")
TIME_BEFORE_JP_DETAIL_RE = re.compile(r"(?P<hour>\d{1,2})時(?:(?P<minute>\d{1,2})分?|(?P<half>半))?\s*(?:まで)")
START_DURATION_COLON_RE = re.compile(r"(?P<hour>\d{1,2})[:：](?P<minute>\d{2})\s*(?:から|〜|~|-)\s*(?P<value>\d{1,3}(?:\.\d+)?)(?:\s*(?P<unit>時間|h|分|minutes?|mins?))?(?![\d:：時])")
START_DURATION_JP_RE = re.compile(r"(?P<hour>\d{1,2})時(?:(?P<minute>\d{1,2})分?|(?P<half>半))?\s*(?:から|〜|~|-)\s*(?P<value>\d{1,3}(?:\.\d+)?)(?:\s*(?P<unit>時間|h|分|minutes?|mins?))?(?![\d:：時])")
EXACT_TIME_JP_RE = re.compile(r"(?P<hour>\d{1,2})時(?:(?P<minute>\d{1,2})分?|(?P<half>半))?(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
EXACT_TIME_COLON_RE = re.compile(r"(?P<hour>\d{1,2})[:：](?P<minute>\d{2})(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
EXACT_TIME_COMPACT_RE = re.compile(r"(?<!\d)(?P<hour>[01]?\d|2[0-3])(?P<minute>[0-5]\d)(?=(?:\s|　)*(?:に|集合|待ち合わせ|出発|開始|頃|ごろ|くらい|ぐらい|予定|$))")
_DATE_SLASH_RE = re.compile(r"(?<!\d)(?:(?P<year>\d{4})[年/-])?(?P<month>1[0-2]|0?[1-9])(?:月|[/-])(?P<day>3[01]|[12]\d|0?[1-9])日?(?![\d:：時分])")
_DATE_JP_RE = re.compile(r"(?:(?P<year>\d{4})年)?(?:(?P<month>1[0-2]|0?[1-9])月(?:の)?)?(?P<day>3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])")
_RELATIVE_DAYS_RE = re.compile(r"(?<!\d)(?P<days>\d{1,2})日後")

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




def _add_months(year: int, month: int, count: int) -> Tuple[int, int]:
    month_index = (year * 12 + (month - 1)) + count
    return month_index // 12, month_index % 12 + 1


def _target_date_from_parts(now: datetime, year_value: Optional[str], month_value: Optional[str], day_value: str, text: str = "") -> Optional[date]:
    try:
        day = int(day_value)
    except Exception:
        return None

    today = now.date()
    normalized = normalize_text(text)

    explicit_year = bool(year_value)
    explicit_month = bool(month_value)

    if explicit_year:
        year = int(year_value)  # type: ignore[arg-type]
    elif "来年" in normalized:
        year = today.year + 1
        explicit_year = True
    else:
        year = today.year
        if "今年" in normalized:
            explicit_year = True

    month = int(month_value) if explicit_month else today.month

    for _ in range(15):
        try:
            target = date(year, month, day)
        except ValueError:
            return None

        if explicit_year or target >= today:
            return target

        if explicit_month:
            year += 1
        else:
            year, month = _add_months(year, month, 1)

    return None


def explicit_date_offset_from_text(text: str, now: datetime) -> Optional[int]:
    normalized = normalize_text(text)
    if not normalized:
        return None

    for pattern in (_DATE_SLASH_RE, _DATE_JP_RE):
        match = pattern.search(normalized)
        if not match:
            continue

        target = _target_date_from_parts(
            now,
            match.groupdict().get("year"),
            match.groupdict().get("month"),
            match.group("day"),
            normalized,
        )
        if not target:
            continue

        offset = (target - now.date()).days
        if 0 <= offset <= 62:
            return offset

    return None


def explicit_relative_day_offset_from_text(text: str) -> Optional[int]:
    normalized = normalize_text(text)
    match = _RELATIVE_DAYS_RE.search(normalized)
    if not match:
        return None

    try:
        days = int(match.group("days"))
    except Exception:
        return None

    return days if 0 <= days <= 62 else None


def weekday_from_text(text: str) -> Optional[int]:
    normalized = normalize_text(text)
    if not normalized:
        return None

    for token, weekday in WEEKDAY_MAP.items():
        if len(token) > 1 and token in normalized:
            return weekday

    for match in re.finditer(r"(?<![0-9])([月火水木金土日])(?=$|[\s　、,。と/／・･にを])", normalized):
        weekday = WEEKDAY_MAP.get(match.group(1))
        if weekday is not None:
            return weekday

    return None


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

    relative_day_offset = explicit_relative_day_offset_from_text(normalized)
    if relative_day_offset is not None:
        return [relative_day_offset], True

    explicit_date_offset = explicit_date_offset_from_text(normalized, now)
    if explicit_date_offset is not None:
        return [explicit_date_offset], True

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

    matched_weekday = weekday_from_text(normalized)

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
        if 0 <= offset <= 62 and offset not in offsets:
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




def _minute_from_any_match(match: re.Match, hour_key: str = "hour", minute_key: str = "minute", half_key: str = "half") -> int:
    return _exact_minute(
        match.group(hour_key),
        match.groupdict().get(minute_key),
        match.groupdict().get(half_key),
    )

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

    start_duration_match = START_DURATION_COLON_RE.search(normalized) or START_DURATION_JP_RE.search(normalized)

    if start_duration_match:
        exact_start_minute = _minute_from_any_match(start_duration_match)
        exact_time_label = _format_minute_label(exact_start_minute)
        not_before = exact_start_minute
        strict_window = True
        labels.append(f"{exact_time_label}開始")
    else:
        range_match = TIME_RANGE_COLON_RE.search(normalized) or TIME_RANGE_JP_DETAIL_RE.search(normalized) or TIME_RANGE_RE.search(normalized)
        if range_match:
            if "start_hour" in range_match.groupdict():
                not_before = _minute_from_any_match(range_match, "start_hour", "start_minute", "start_half")
                not_after = _minute_from_any_match(range_match, "end_hour", "end_minute", "end_half")
            else:
                not_before = _minute_from_match(range_match.group("start"), range_match.group("start_half"))
                not_after = _minute_from_match(range_match.group("end"), range_match.group("end_half"))

            exact_start_minute = not_before
            exact_time_label = _format_minute_label(not_before)
            strict_window = True
            labels.append(f"{_format_minute_label(not_before)}-{_format_minute_label(not_after)}")
        else:
            after_match = TIME_AFTER_COLON_RE.search(normalized) or TIME_AFTER_JP_DETAIL_RE.search(normalized) or TIME_AFTER_RE.search(normalized)
            if after_match:
                not_before = _minute_from_any_match(after_match)
                strict_window = True
                labels.append(f"{_format_minute_label(not_before)}以降")

                if "から" in after_match.group(0):
                    exact_start_minute = not_before
                    exact_time_label = _format_minute_label(not_before)

            before_match = TIME_BEFORE_COLON_RE.search(normalized) or TIME_BEFORE_JP_DETAIL_RE.search(normalized) or TIME_BEFORE_RE.search(normalized)
            if before_match:
                not_after = _minute_from_any_match(before_match)
                strict_window = True
                labels.append(f"{_format_minute_label(not_after)}まで")

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
