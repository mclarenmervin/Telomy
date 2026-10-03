from app.activity_agent.prompts import build_system_prompt


def state(**kw):
    base = {
        "session": {"activity_type": "cycling"},
        "analysis": {"duration_seconds": 1800, "data_quality": "full", "metrics": [],
                     "score": None, "baseline": {}, "history_used": {}},
        "insights": [], "data_gaps": [], "profile": {"displayName": "Asha"},
        "safety_facts": [], "previous_report": None, "severity": "normal",
    }
    base.update(kw)
    return base


def test_prompt_states_the_persona_and_its_limit():
    prompt = build_system_prompt(state(), None)

    assert "not a clinician" in prompt.lower()
    assert "diagnos" in prompt.lower()


def test_prompt_forbids_supplements_as_well_as_medication():
    prompt = build_system_prompt(state(), None)

    assert "supplement" in prompt.lower()


def test_prompt_carries_the_honesty_rule():
    """Without it a warm persona softens attention findings into nothing."""
    prompt = build_system_prompt(state(), None)

    assert "reassur" in prompt.lower()


def test_prompt_tells_the_model_the_computed_severity():
    """ROLE itself contains the word "attention", so asserting on that alone passes
    with the severity block deleted. Assert on the labelled line and on the prompts
    actually differing between severities."""
    raised = build_system_prompt(state(severity="attention"), None)
    normal = build_system_prompt(state(severity="normal"), None)

    assert "SEVERITY (decided by our rules, not yours): attention" in raised
    assert "SEVERITY (decided by our rules, not yours): normal" in normal
    assert raised != normal


def test_prompt_describes_the_tools_it_may_call():
    prompt = build_system_prompt(state(), None)

    for hint in ("lab", "measurement", "sleep"):
        assert hint in prompt.lower()


def test_prompt_never_suggests_giving_a_phone_number():
    prompt = build_system_prompt(state(), None)

    assert "phone number" not in prompt.lower()


def test_no_deterministic_copy_anywhere_contains_a_phone_number():
    """D5: no phone number in agent output. The Flutter test asserts on strings the
    test itself wrote, so the backend's real copy was never covered."""
    import re

    from app.activity_agent.report import ESCALATION_COPY
    from app.agent.guardrails import ESCALATION_LINE, SAFE_FALLBACK
    from app.activity_agent.prompts import ROLE

    phone = re.compile(r"\+?\d[\d\s().-]{6,}")
    corpus = [ROLE, ESCALATION_LINE, SAFE_FALLBACK]
    corpus += [part for pair in ESCALATION_COPY.values() for part in pair]

    for text in corpus:
        assert not phone.search(text), text
