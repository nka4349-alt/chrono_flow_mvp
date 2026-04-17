from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


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


class ToolInvocation(BaseModel):
    tool_name: str
    status: str = "success"
    position: int = 0
    duration_ms: Optional[int] = None
    input_payload: Dict[str, Any] = Field(default_factory=dict)
    output_payload: Dict[str, Any] = Field(default_factory=dict)
    metadata: Dict[str, Any] = Field(default_factory=dict)


class PolicyRun(BaseModel):
    provider: str = "rules-engine"
    policy_version: Optional[str] = None
    route: str = "rules_engine"
    request_kind: str = "chat_message"
    duration_ms: Optional[int] = None
    prompt_snapshot: Dict[str, Any] = Field(default_factory=dict)
    context_snapshot: Dict[str, Any] = Field(default_factory=dict)
    result_metadata: Dict[str, Any] = Field(default_factory=dict)


class ChatResponse(BaseModel):
    provider: str
    assistant_message: str
    recommendations: List[Recommendation] = Field(default_factory=list)
    policy_run: PolicyRun = Field(default_factory=PolicyRun)
    tool_invocations: List[ToolInvocation] = Field(default_factory=list)
