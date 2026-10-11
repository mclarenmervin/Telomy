"""One turn of the conversation.

The model is one step in the middle of this file. Everything else is
deterministic, and that is the design rather than an accident of implementation
— so it is worth saying what each step is for, in the order they run.

**Before the model**

1. The message is screened for emergency language, by `analytics/safety.py`,
   with no model involved. A model having a bad generation must never be the
   thing standing between somebody in crisis and a phone number, so the turn
   ends here when it fires.
2. The budget. `max_llm_calls` and `max_tool_calls` bound one turn from inside
   the agent; this bounds the number of turns, which is the part an agent that
   loops cannot reach. A chat turn is the easiest place in this product to
   spend hundreds of dollars unnoticed.
3. Context is read — history, signed insights, open escalations, the profile,
   the recorded medications — all through the one scoped loader, every query
   filtered by `user_id`.

**The model**

It gets tools, and nothing else. Every number it may state comes from a tool
call in this turn; it is given no measurements in its prompt to recite from
memory, and it computes nothing (P2).

**After the model**

4. The figure check: a number with a unit beside it that no tool returned is an
   invented measurement about somebody's body, and the reply does not go out.
5. The guardrails, in the `quoting_signed` profile, so the model may repeat a
   clinician's signed words and nothing else.
6. The promise check, because there is no clinician console yet and "a
   clinician will get back to you" is a sentence a person acts on by waiting.
7. The escalation line, if a critical lab value is sitting unacknowledged. It
   is appended last so it survives every replacement above, and it is never
   gated on the route, the profile, or whether the model worked at all — a
   critical value cannot wait for a conversation and must never be delayed by
   one.
8. The turn is recorded.

Chat bypasses the job queue, as CLAUDE.md already settled: a human is waiting,
and routing that behind ten thousand weekly reports makes it unusable. So this
runs in the gateway, and steps 1, 2 and 7 are the reasons that is safe.

**Why there is no token streaming.** Step 5 is the last deterministic thing
between a model and a user, and it operates on the finished text: a rule can
replace a reply, but nothing can un-say a token already on somebody's screen.
A streamed concierge would have to either run the guardrails on fragments,
which no pattern here survives, or show text it has not checked. So a turn
answers once, whole. Progress events are a legitimate thing to stream later;
the reply is not.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable

from app.agent.guardrails import (
    ESCALATION_LINE,
    QUOTING_SIGNED,
    SAFE_FALLBACK,
    UNKEEPABLE_PROMISE_FALLBACK,
    apply_guardrails,
    own_words,
    promises_human_action,
)
from app.agent.numbers import check_numbers, collect_tool_numbers
from app.analytics.safety import screen_for_emergency
from app.common.logging_config import get_logger, log_context
from app.concierge.grounding import quotable_bodies, quoted_insight_ids
from app.concierge.persist import save_turn
from app.concierge.state import ConciergeContext

logger = get_logger(__name__)

#: Matches the check constraint on `chat_turns.asked`. Enforced in both places
#: on purpose: the database is the boundary that cannot be forgotten, and this
#: is the one that can refuse without losing the exchange.
MAX_MESSAGE_CHARS = 2000

#: The model answered and every check left it alone.
ANSWERED = "answered"
#: A rule matched. The user read a fallback, not what the model wrote.
GUARDRAIL_REPLACED = "guardrail_replaced"
#: The emergency screen fired before any model ran.
EMERGENCY = "emergency"
#: No model configured, or the call failed. An honest fallback went out.
UNAVAILABLE = "unavailable"

#: What the user reads when there is no model to answer with. It says what it
#: cannot do and what it can, because "something went wrong" sends somebody who
#: is worried about a blood test away with nothing.
UNAVAILABLE_TEXT = (
    "I can't answer in my own words right now. Your readings, lab results and "
    "any findings a clinician has signed are all still on their screens in the "
    "app, and nothing about them has changed."
)


class TurnRefused(Exception):
    """This turn will not be answered, and nothing was spent finding out.

    Carries a machine-readable `reason` so the gateway can map it to a status
    code without parsing prose.
    """

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason
        self.message = message


#: Refusal reasons. `rate_limited` is the only one a well-behaved client can
#: hit; the others mean the client did not validate before asking.
EMPTY = "empty"
TOO_LONG = "too_long"
RATE_LIMITED = "rate_limited"


@dataclass(frozen=True)
class Turn:
    asked: str
    answered: str
    route: str
    flags: list[str] = field(default_factory=list)
    quoted_insight_ids: list[str] = field(default_factory=list)
    model: str | None = None


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _reply_text(result) -> str | None:
    """The model's answer, which is the content of its last non-tool message.

    `None` when there is nothing usable, which is treated exactly like a failed
    call: an empty reply shown as an answer reads as the product having nothing
    to say about the person's health.
    """
    if not isinstance(result, dict):
        return None
    for message in reversed(result.get("messages") or []):
        if getattr(message, "type", None) == "tool":
            continue
        content = getattr(message, "content", None)
        if isinstance(content, str) and content.strip():
            return content.strip()
    return None


class Concierge:
    """Answers one message at a time, holding no state between turns (P3).

    `narrator` is injected rather than built here so that the deterministic
    steps can be tested without a model — which is most of what is worth
    testing. A falsy narrator is a supported state, not a failure: it degrades
    the wording to an honest fallback rather than breaking the feature, the
    same way both existing agents handle a missing key.
    """

    def __init__(
        self,
        loader,
        supabase,
        settings,
        narrator=None,
        now: Callable[[], datetime] = _utcnow,
    ):
        self._loader = loader
        self._db = supabase
        self._settings = settings
        self._narrator = narrator
        self._now = now

    # ── The turn ─────────────────────────────────────────────────────────────

    def answer(self, user_id: str, message: str, display_name: str | None = None) -> Turn:
        asked = (message or "").strip()
        if not asked:
            raise TurnRefused(EMPTY, "there is no question here")
        if len(asked) > MAX_MESSAGE_CHARS:
            # Refused rather than truncated: answering the first 2000 characters
            # of a longer question answers a question nobody asked.
            raise TurnRefused(
                TOO_LONG, f"a message must be {MAX_MESSAGE_CHARS} characters or fewer"
            )

        emergency = screen_for_emergency(asked)
        if emergency is not None:
            # Deliberately before the budget check as well as before the model:
            # somebody describing chest pain must not be rate-limited, and the
            # response costs nothing to produce.
            logger.warning(
                "emergency language in a chat turn "
                f"{log_context(user_id=user_id)} rule={emergency.matched_rule}"
            )
            return self._record(
                user_id,
                Turn(
                    asked=asked,
                    answered=emergency.response,
                    route=EMERGENCY,
                    flags=["emergency", emergency.category],
                ),
            )

        self._check_budget(user_id)

        history = self._loader.chat_turns(
            user_id, limit=self._settings.chat_history_turns
        )["items"]
        insights = self._loader.clinical_insights(user_id)["items"]
        quotable = quotable_bodies(insights)
        escalations = self._loader.open_lab_escalations(user_id)["items"]
        profile = self._loader.user_profile(user_id)["items"]
        safety = self._loader.safety_facts(user_id)["items"]

        reply, tool_numbers = self._narrate(
            user_id=user_id,
            asked=asked,
            history=history,
            profile=(profile[0].get("profile") if profile else {}) or {},
            safety_facts=safety,
            escalations=escalations,
            display_name=display_name,
        )

        if reply is None:
            turn = Turn(
                asked=asked,
                answered=UNAVAILABLE_TEXT,
                route=UNAVAILABLE,
                flags=["narration_unavailable"],
            )
        else:
            turn = self._guard(asked, reply, tool_numbers, quotable, insights)

        if escalations:
            # Last, so it survives every replacement above, and ungated so it
            # survives the model being down. Nothing here writes
            # `acknowledged_at`: chat is not allowed to be the thing that marks
            # an emergency as handled.
            turn = Turn(
                asked=turn.asked,
                answered=f"{turn.answered} {ESCALATION_LINE}",
                route=turn.route,
                flags=[*turn.flags, "escalation"],
                quoted_insight_ids=turn.quoted_insight_ids,
                model=turn.model,
            )

        return self._record(user_id, turn)

    # ── The steps ────────────────────────────────────────────────────────────

    def _check_budget(self, user_id: str) -> None:
        since = (self._now() - timedelta(hours=24)).isoformat()
        spent = self._loader.turns_since(user_id, since)
        if spent >= self._settings.max_chat_turns_per_day:
            logger.warning(
                f"chat turn refused on the daily cap {log_context(user_id=user_id)} "
                f"spent={spent}"
            )
            # Raised before anything is spent, and no row is written: a turn
            # that never ran would otherwise count towards the cap that
            # produced it.
            raise TurnRefused(
                RATE_LIMITED,
                "you have reached today's limit for questions. It resets through "
                "the day.",
            )

    def _narrate(self, *, user_id, asked, history, profile, safety_facts,
                 escalations, display_name) -> tuple[str | None, set[str]]:
        """Run the model, or report that there is none.

        Returns the reply and the numbers its tools actually returned. Never
        raises: a provider outage is an honest fallback, not a 500 at somebody
        who asked about their blood test.
        """
        if not self._narrator:
            return None, set()

        messages = []
        for turn in reversed(history):  # the loader returns newest first
            messages.append({"role": "user", "content": turn.get("asked") or ""})
            messages.append({"role": "assistant", "content": turn.get("answered") or ""})
        messages.append({"role": "user", "content": asked})

        try:
            result = self._narrator.invoke(
                {
                    "messages": messages,
                    "profile": profile,
                    "safety_facts": safety_facts,
                    "escalations": escalations,
                },
                context=ConciergeContext(user_id=user_id, display_name=display_name),
            )
        except Exception:
            logger.exception(f"a chat turn failed to narrate {log_context(user_id=user_id)}")
            return None, set()

        return _reply_text(result), collect_tool_numbers(result.get("messages"))

    def _guard(self, asked: str, reply: str, tool_numbers, quotable, insights) -> Turn:
        """Every deterministic check on what the model said, and the one
        decision they add up to: does this text reach the user, or does a
        fallback?"""
        # The same subtraction the guardrail makes, for the same reason: a
        # clinician's signed sentence is full of figures that no tool returned
        # as values, because they are inside a string. Judging the quote as the
        # model's own arithmetic would make every signed finding unquotable,
        # which is the bug this phase opened with.
        mine = own_words(reply, quotable)

        flags: list[str] = []
        figures = check_numbers(mine, tool_numbers)
        if figures.measurements:
            # A number with a unit beside it, tracing to nothing. This is the
            # worst thing the feature can do: an invented blood test, in the
            # product's own voice, about this person.
            flags.append("unsupported_measurement")
            logger.warning(f"unsupported measurement in a chat reply: {sorted(figures.measurements)}")
        elif figures.unverified:
            # Dates, counts and ordinals. Worth counting, not worth refusing a
            # whole reply over -- a check that fires on every honest sentence
            # is a check somebody eventually switches off.
            flags.append("unverified_number")

        guarded, guardrail_flags = apply_guardrails(
            reply, {"metrics": {}}, profile=QUOTING_SIGNED, signed_bodies=quotable
        )
        flags.extend(f for f in guardrail_flags if f not in flags)

        promised = promises_human_action(mine)
        if promised:
            flags.append("unkeepable_promise")

        # Priority is the order of harm. Medical content the model was not
        # entitled to write outranks a promise it cannot keep, and both outrank
        # letting the text through.
        medical = bool({"diagnosis", "medication"} & set(guardrail_flags)) or bool(
            figures.measurements
        )
        if medical:
            answered, route = SAFE_FALLBACK, GUARDRAIL_REPLACED
        elif promised:
            answered, route = UNKEEPABLE_PROMISE_FALLBACK, GUARDRAIL_REPLACED
        else:
            answered, route = guarded, ANSWERED

        # Only what actually went out is recorded as quoted. A fallback quotes
        # nobody, and attributing a clinician's words to a reply the user never
        # saw would make the trail say the opposite of what happened.
        quoted = quoted_insight_ids(answered, insights) if route == ANSWERED else []

        return Turn(
            asked=asked,
            answered=answered,
            route=route,
            flags=flags,
            quoted_insight_ids=quoted,
            model=self._settings.llm_model,
        )

    def _record(self, user_id: str, turn: Turn) -> Turn:
        save_turn(self._db, user_id, turn)
        logger.info(
            f"chat turn {log_context(user_id=user_id)} route={turn.route} "
            f"flags={turn.flags}"
        )
        return turn
