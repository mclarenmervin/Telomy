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
    prompt = build_system_prompt(state(severity="attention"), None)

    assert "attention" in prompt


def test_prompt_describes_the_tools_it_may_call():
    prompt = build_system_prompt(state(), None)

    for hint in ("lab", "measurement", "sleep"):
        assert hint in prompt.lower()


def test_prompt_never_suggests_giving_a_phone_number():
    prompt = build_system_prompt(state(), None)

    assert "phone number" not in prompt.lower()
