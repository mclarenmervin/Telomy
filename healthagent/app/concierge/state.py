"""Per-turn runtime context.

`user_id` is written once at entry and never mutated — the rule the activity
agent's context follows, and the reason a tool can read identity from here
instead of taking it as an argument. There is no session id, because a
conversation is not about one event, and no thread id either: the history a
turn is answered against is read from Postgres at entry rather than carried in
the context, so a worker holds no user state between turns.
"""

from dataclasses import dataclass

from langchain.agents.middleware import AgentState


@dataclass(frozen=True)
class ConciergeContext:
    user_id: str
    display_name: str | None = None


class ConciergeState(AgentState):
    """What the prompt reads, beyond the messages.

    Deliberately short, and deliberately carrying no measurements: everything
    the model may state about the person's body comes from a tool call in this
    turn. `profile` is here for their name, `safety_facts` so a recorded
    medication is taken into account without being named, and `escalations` so
    the model does not reassure somebody who has an unacknowledged critical
    lab value — the line about that is appended deterministically afterwards
    either way.
    """

    profile: dict
    safety_facts: list
    escalations: list
