Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F13) and decisions 4, 5
and 6. Decision 5 is the phase's defining constraint and decision 6 says what
not to ship.
healthagent/CLAUDE.md — "Verify the webhook secret before reading any field",
"Never call an LLM in the telemetry path", and P4 (ingest never coupled to
compute). All three are this phase.
The prototype's docs/DEVICE_INTEGRATION.md — the best single document in that
repository. Three streams describing one session, the channel table with hard
limits per machine type, and the key-rotation flow. Port the contract, not the
code.

What F13 is: machines. A device registry with per-device keys that can be
rotated, a channel schema per machine type with hard limits and alarms, the
telemetry endpoint, the body-signal endpoint for a patch or a chest strap, the
live therapy floor that refreshes every fifteen seconds, and in-session
physiology: HR surge and time to peak, HRV suppression and rebound at 15–21
minutes, recovery constant *k* from a log-linear fit, rewarming half-time, SpO₂
kinetics, cardiac load, and deterministic safety tiers.

Already built (F0–F12), reuse it:

app/gateway/activity_webhooks.py + lab_webhooks.py — the webhook shape, and the
  verification-before-field-read rule they already obey
app/common/queue.py — `DelayedQueue`. Telemetry acknowledges in milliseconds and
  computes on the queue (P4). A 20,000-sample batch must not block a worker
app/activity_worker/main.py — the worker shape to clone
app/analytics/activity_analysis.py — pure-function style, cumulative-versus-
  interval handling, and the fact that cross-source dedupe is **not** solved
F12's session record — prescribed and delivered dose already exist on it. F13
  fills `delivered`
app/analytics/safety.py — in-session tiers belong beside the contraindication
  rules, as rules

Ten things that will bite you:

1. **A bad device key is refused before any field is read.** The prototype
   hashes keys and checks before parsing; our rule is stricter and already
   written in CLAUDE.md. A telemetry endpoint that parses first is an
   unauthenticated writer into the therapy record.

2. **Telemetry is polled-shaped, not event-shaped.** 1–10 s resolution, batches
   of 60–120 samples, up to 20,000 per request. The decided pattern in CLAUDE.md
   is webhooks for events and polling for telemetry, for exactly this reason:
   a webhook per sample is millions of calls a day with no backpressure.
   Acknowledge, enqueue, compute elsewhere.

3. **Unknown channels are ignored, never stored.** The prototype's rule, and it
   is the right one: a machine firmware update that adds a field must not silently
   create a column of unvalidated numbers. `GET /devices/channels` is the
   authoritative list; ours lives in code with the hard limits beside it.

4. **A value outside a hard limit is an alarm, not a row to clean up later.**
   HBOT pressure, PEMF coil at 45 °C (a firmware cut-off, not a preference),
   SpO₂ floors — these reach the floor screen and a staff member, in the same
   response that rejected them.

5. **Implausible sensor values are rejected loudly before they touch a
   baseline.** HR of 0 or 300. The approved plan's edge-case list says it and
   this is the phase that can poison a baseline in a minute.

6. **Simulated physiology is labelled simulated, everywhere, always
   (decision 5).** The prototype's `physio.py` integrates a first-order state
   model to *predict* what happens inside a cryo chamber, and its own clinical
   safety doc requires simulated values to be labelled wherever they appear.
   That model is genuinely useful — it is what lets a member see what a therapy
   will do before they book it — and it is also the single most dangerous thing
   in this programme, because a predicted HRV rebound rendered beside a measured
   one is indistinguishable. Two different components, two different labels, and
   the guardrails enforce it rather than the reviewer. If only one thing from
   this prompt survives, it is this.

7. **Measured and predicted must never merge into one chart series.** Follows
   from 6 and is worth its own line, because the prototype's session screen is
   the exact place the temptation appears.

8. **HSAI is specified and not shipped (decision 6).** It is a weighted composite
   over seven domains with no test–retest data and no validation against
   anything, and it is the easiest number in the product to mistake for a
   diagnosis. Build the domain inputs — this phase produces most of them — and
   leave the index behind a flag with no UI. Whoever wants it shipped can say so
   in writing after someone validates it.

9. **The live floor is a real-time screen, so decide what happens when it is
   wrong.** Fifteen-second polling, a stale read, a device that stopped
   reporting mid-session: the screen says "last seen 2 minutes ago", never a
   frozen number that looks live. Staff will trust this screen more than they
   trust us.

10. **Which machines can speak at all is still open.** Open question 3 in
    CLAUDE.md, unanswered since the platform HLD, and it gates the real half of
    this phase. The contract and the simulator can be built without it; the
    integration cannot. Ask before the phase, not during it.

Verification:

- Bad key, no key, revoked key, rotated key: refused before parse, proved by a
  test that asserts no parse occurred.
- A 20,000-sample batch acknowledges in milliseconds and computes on the queue.
- Out-of-limit channel → alarm in the response and on the floor.
- HR of 0 and of 300 rejected before any baseline update.
- A simulated trace and a measured trace rendered side by side, with a test that
  asserts the simulated one carries its label and cannot be styled as measured.
- A session where the device stops reporting halfway: the floor shows staleness.
- Recovery constant *k*, rebound and rewarming half-time asserted against a
  hand-worked fixture.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout. Mutate the key check and watch an
unauthenticated write succeed, then put it back. Small commits that say why.
Both suites green before each commit. Push to staging. Verify on `Pixel_8` —
and if a real machine is available, on that, once, before the phase is called
done.

Deliberately left for later:
- MQTT (decision 4), the device simulator as production tooling, PINN-trained
  physiology, the response-phenotype study.
- HSAI's UI (bite 8).
- Cross-source wearable dedupe. Still unsolved, now with a third stream.
