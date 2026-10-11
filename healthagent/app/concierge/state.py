"""Per-turn runtime context.

`user_id` is written once at entry and never mutated — the rule the activity
agent's context follows, and the reason a tool can read identity from here
instead of taking it as an argument. There is no session id, because a
conversation is not about one event, and no thread id either: the history a
turn is answered against is read from Postgres at entry rather than carried in
the context, so a worker holds no user state between turns.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class ConciergeContext:
    user_id: str
    display_name: str | None = None
