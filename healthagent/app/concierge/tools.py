"""What the concierge may look at.

The data tools are the activity agent's, unchanged and not copied. Everything
here beyond them answers a question a conversation asks and a session report
does not.

There is deliberately no tool that computes anything. Every number the
concierge states is one the server already computed and stored, which is the
only way a sentence and a chart can be guaranteed to agree — recomputing
readiness a second later from slightly different data is the dual-math defect
with extra steps, and F2 spent a phase closing it.
"""

from langchain.tools import ToolRuntime, tool

from app.agent.data_tools import UserScope, build_data_tools
from app.analytics.scores import READINESS


def build_concierge_tools(loader) -> list:
    @tool
    def get_readiness(runtime: ToolRuntime[UserScope]) -> dict:
        """The user's readiness score, as stored.

        This is the number on the user's own dashboard. Quote it with its
        `as_of_date` — readiness is computed for a day and the latest stored
        one may not be today's.

        `value` may be null, and null means UNKNOWN: never zero, never
        "average". `missing_inputs` says what the computation did not have, and
        `data_quality` of "partial" or "none" means say so rather than
        presenting the number as settled. Do NOT estimate or infer a readiness
        score yourself under any circumstances.

        `drivers` carry each input's contribution and its weight. Report them
        as written; the arithmetic behind them is already done.
        """
        return loader.score_snapshot(runtime.context.user_id, READINESS)

    return [*build_data_tools(loader), get_readiness]
