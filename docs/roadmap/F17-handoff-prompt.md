Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F17).
healthagent/CLAUDE.md — P1 (one event contract) and Build Order step 8. Voice is
additive by construction because it is a third writer to the same table, and
that is the whole design.
healthagent/app/concierge/turn.py — the deterministic step order, and the only
place a model's words reach a user with no human in between. Voice adds an input
to it, not a second one of it.
healthagent/app/agent/guardrails.py — `apply_guardrails`, the profiles,
`gate_delivery`. A spoken answer is an answer.

What F17 is: three input methods that all end up as ordinary rows. Voice to text
to an `events` row — the same row shape a button press produces, which is P1 and
means nothing downstream may be able to tell which fired. Voice-stress acoustics
as an explicitly evidence-C wellness signal. Routines described in plain language
and parsed into a weekly schedule with adherence. Custom activity types — a fast
bowler's spell, a round of golf — created by voice or by hand, with their own
baselines.

Already built (F0–F16), reuse it:

events — P1. The contract. Everything in this phase writes it
app/concierge/ — turn, tools, prompt, grounding. The intent path for a spoken
  command reuses the concierge's tools; it does not get its own
app/agent/data_tools.py — user-scoped tools, none taking a `user_id`. A new tool
  goes here unless it only makes sense for one caller
app/analytics/activity_analysis.py — baselines, median ± MAD, and the
  acute:chronic ratio. A custom activity type is a new label over the same maths
app/common/usertime.py + timeparse.py — "yesterday evening", "every morning
  except Sunday". Natural-language time is already solved here; do not re-solve it
app/clinical/ — anything the routine parser turns into advice goes through it

Nine things that will bite you:

1. **Transcription is not understanding, and both can fail silently.** A
   misheard "two pegs" becomes an event the user never logged. Every voice-
   created row is confirmable and shows the transcript it came from; the
   prototype logs the action for exactly this reason. Auto-detected events
   already require confirmation (a decided question in CLAUDE.md) — spoken ones
   are the same class.

2. **Numbers in speech are the dangerous part.** "Thirty minutes" versus "three
   zero minutes" versus "13 minutes". The parser extracts a number, the user
   confirms the number, and the model never does arithmetic on it (P2).

3. **Voice stress is evidence C and must read like it.** F0 mean and CV, jitter,
   shimmer, HNR, speech rate, pause ratio, against the person's own baseline.
   It is a wellness signal, it is fused with HRV in the prototype at 50/50, and
   it is not a clinical measure of anything. The claims firewall applies: never
   "you are stressed", never a mental-health inference, and never an input to a
   clinical decision.

4. **Audio is the most sensitive data the product will hold.** Decide retention
   before the first sample: what is kept, for how long, whether the waveform is
   discarded once features are extracted (recommendation: yes, keep features,
   discard audio, and say so in the consent). Erasure must purge it, including
   from Storage — the omission the approved plan already caught once for lab
   PDFs.

5. **Local Whisper is a deployment decision, not a library choice.** The
   prototype runs it optionally on a laptop. On Railway it is a model download, a
   cold start and a memory ceiling. Decide where transcription runs before
   building the client, and keep the interface narrow enough that the answer can
   change.

6. **A routine is a plan, and a plan that tells someone what to do is
   clinical.** "Sauna three times a week" parsed from free text is a schedule;
   "sauna three times a week for your blood pressure" is advice. The parser
   produces the schedule, the adherence metric and nothing else; any causal
   claim attached to it goes through F10.

7. **Adherence is a judgement about a person and will be read as one.** Phrase
   it as what happened, not as a score out of ten. A member who had a bad week
   does not need the app to grade them.

8. **A custom activity with three sessions has no baseline.** Minimum sessions
   before a baseline, before an insight, before a comparison — and the screen
   says which it is waiting for. The prototype uses a median ± MAD of the last
   ten; below that, say so.

9. **Always-on listening is not in this phase (and the prototype's own screen
   for it is honest about being a description, not a feature).** Push-to-talk
   only. A wake word needs a native build, a speaker-verification answer and a
   different consent.

Verification:

- A spoken event and a tapped event produce rows that are byte-identical apart
  from their source; assert downstream code cannot distinguish them.
- A misheard number: the confirmation path catches it, and nothing was written
  before confirmation.
- Voice features extracted, audio discarded, erasure proved against Storage.
- A routine with an exception clause ("every morning except Sunday") parsed
  correctly, and one ambiguous enough that the right answer is to ask.
- An activity below its minimum session count: no baseline, honest screen.
- Voice stress rendered with its evidence grade, and absent from every clinical
  path, asserted by a test that walks the clinical inputs.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout, small commits that say why, both suites green,
push to staging, verify on `Pixel_8` — microphone permissions and the recording
UI are device-only behaviour and have never been exercised in this app.

Deliberately left for later:
- Always-on mode and the wake word (bite 9), speaker verification, Indic-language
  models beyond whatever the chosen transcription path gives for free.
- The detector (Build Order step 9) is still blocked on the wearable question and
  is not this phase, even though voice makes the same table busier.
