from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List

from .planner import llm_plan
from .tools.calendar_tools import extract_date_constraints, extract_time_preferences, summarize_calendar
from .tools.social_tools import resolve_entities

TOOL_USE_VERSION = "tool-registry-v2"


def _tool_record(tool_name: str, inputs: Dict[str, Any], outputs: Dict[str, Any], status: str = "ok") -> Dict[str, Any]:
    return {
        "tool_name": tool_name,
        "status": status,
        "inputs": inputs,
        "outputs": outputs,
    }


def run_tools(scope: str, user_message: str, context: Dict[str, Any], now: datetime) -> Dict[str, Any]:
    plan = llm_plan(context) or {}
    day_offsets = list(plan.get("day_offsets") or [])
    strict_day = bool(plan.get("strict_day"))
    planned_name = (plan.get("contact_name") or "").strip() or None

    results: Dict[str, Any] = {}
    invocations: List[Dict[str, Any]] = []

    date_result = extract_date_constraints(
        now=now,
        user_message=user_message,
        planned_day_offsets=day_offsets,
        planned_strict_day=strict_day,
    )
    results["date_constraints"] = date_result
    invocations.append(
        _tool_record(
            "date_constraints",
            {"message": user_message, "day_offsets": day_offsets, "strict_day": strict_day},
            date_result,
        )
    )

    time_result = extract_time_preferences(user_message)
    results["time_preferences"] = time_result
    invocations.append(
        _tool_record(
            "time_preferences",
            {"message": user_message},
            time_result,
        )
    )

    calendar_result = summarize_calendar(
        context=context,
        now=now,
        day_offsets=date_result.get("day_offsets") or [],
        strict_day=bool(date_result.get("strict_day")),
    )
    results["calendar_summary"] = calendar_result
    invocations.append(
        _tool_record(
            "calendar_summary",
            {
                "scope": scope,
                "day_offsets": date_result.get("day_offsets") or [],
                "strict_day": bool(date_result.get("strict_day")),
            },
            {
                "evaluated_days": calendar_result.get("evaluated_days") or [],
                "total_busy_minutes": calendar_result.get("total_busy_minutes") or 0,
            },
        )
    )

    social_result = resolve_entities(user_message, context=context, planned_contact_name=planned_name)
    results["social_resolver"] = social_result
    invocations.append(
        _tool_record(
            "social_resolver",
            {"planned_contact_name": planned_name, "message": user_message},
            {
                "resolved_contact_name": social_result.get("resolved_contact_name"),
                "matched_from": social_result.get("matched_from"),
                "social_signal": bool(social_result.get("social_signal")),
            },
        )
    )

    context["_tool_results"] = results
    context["_tool_invocations"] = invocations
    if social_result.get("resolved_contact"):
        context["_resolved_contact"] = social_result["resolved_contact"]
    if date_result.get("day_offsets"):
        context["_resolved_day_offsets"] = date_result["day_offsets"]
        context["_resolved_strict_day"] = bool(date_result.get("strict_day"))
    if time_result:
        context["_resolved_time_preferences"] = time_result

    return {"version": TOOL_USE_VERSION, "tool_invocations": invocations, "results": results}
