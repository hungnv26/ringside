# Jev + frontier model: a corner with reflexes and a brain

Plan written 2026-10-30. Built 2026-10-31 on the `jev` branch (phases 0 to 5 below); see
"Status" at the end for what ran and what still needs a key.

## Idea

Today one model does everything for a corner: every 2 s (coach mode) it reads the fight, sets the
plan, queues moves, makes a read and talks. Frontier models reason well but a turn costs one to
several seconds and a few cents, so the fighter runs on a stale plan most of the time.

[Jev](https://en.wikipedia.org/wiki/Jev_(AI_model)) (TypeSafe AI, early access since 2026-09-15)
is a decision model, not a chat model: it takes a block of state and a batch of typed questions
(`noul` yes/no, `choice`, `score`) and answers all of them in one pass with calibrated
probabilities, in 70 to 500 ms, for about $0.04 per million input tokens with output free. It
writes no text and no code.

Split the corner in two:

- **System 1, the reflexes (Jev)**: every state frame (4 per second) it nudges the plan knobs,
  makes a read when it is confident, and decides whether System 2 is needed.
- **System 2, the brain (a frontier model)**: at round start, after a knockdown, on a 25% health
  swing, and whenever Jev's gate fires. It sets the baseline plan, queues combos, writes the
  corner talk, and writes *standing orders* that become part of Jev's state, so the brain
  programs the reflexes. In self-coding mode it also rewrites the rule set and Jev's criteria
  after each round, which is the only way Jev "learns".

A corner can also run Jev alone (reflexes, templated captions, no combos) as a cheap baseline
entrant in the Elo table.

## What Jev decides, what it cannot

| Tool today | Jev | How |
| --- | --- | --- |
| `set_plan` | yes | `score` over 5 levels for aggression, block, punish, anti_air, pressure; `choice` for range (close/mid/far) and reaction; one `choice` "which option family to favour now" instead of 15 weights |
| `predict` | yes, best fit | `choice` over the opponent's specials + the read words + "nothing"; sent only when the top probability clears a threshold and no read is pending |
| `queue` | no | ordered combos stay with the brain; Jev only raises a `noul` "a punish or super window is open now" that wakes the brain |
| `say` | no | reflex captions are templated from its answers ("close, block up, expecting 623P") |
| `set_policy` | no | the brain writes rules; Jev runs the gate and the read during the round |

Gates (`noul`, one call with everything else): *the plan in force is failing*, *a queue window is
open*, *the opponent changed pattern*. A gate fires the brain's turn with a cooldown so the
frontier model is called at most every few seconds and usually far less.

## Spec grammar and entrants

- `provider:model` unchanged: the brain alone (today's coach).
- `provider:model+jev`: brain plus reflexes. The `+jev` suffix stays in the spec so the Elo
  table, logs and cost per side treat the hybrid as its own entrant.
- `jev:jev`: reflexes alone.

Keys: `infra/keys/jev.key`, a DigitalOcean model access key (Jev is in the DO model catalog and
served at `inference.do-ai.run/v1/systemone` without a TypeSafe account, but only for accounts on
Tier 3 or above: a $250 prepayment, found 2026-10-31) or a TypeSafe API key from console.typesafe.ai
with `JEV_URL=https://api.typesafe.ai/v1/systemone` (same body; the model id is `jev-latest` there,
`$JEV_MODEL` overrides). The Vercel AI Gateway is the fallback. Jev is not OpenAI-compatible, so it
does not go through `ProviderClient`'s chat translation; it gets its own client.

## Phases

### 0. Probe before building (half a day)

`tools/jev_probe.mjs`: replays logged turns from `battle-logs/<id>/<side>.md` (every turn's
prompt is kept) as Jev state, asks the plan and read questions, and scores the reads against the
`read` events and the next attacks that actually came. Reports latency, tokens per call,
precision of reads at thresholds 0.5/0.6/0.7, and how often each gate would have fired.

Go/no-go: reads at 0.6 at least as precise as the LLM coaches' reads in the same logs
(`reads.right / reads.made` in `battle.json`), and p95 latency under 500 ms. If the reads are
noise, stop at a Jev-only entrant for the Elo table and do not build the hybrid.

### 1. Jev client and question set (one day)

- `adapter/src/jev.ts`: `JevClient.decide(state, questions)` → answers with probabilities, usage
  and USD (price entry `jev:jev` in `design/model_prices.json`: in 0.042, out 0). Timeout 2 s,
  one request in flight per side, a dropped tick when one is still running.
- `jevQuestions(side, hello)`: the fixed question set above, built once per match from the
  fighters' move lists (criteria name each special by input and name).
- `jevState(side, state, events, plan, orders)`: the state block, reusing `buildTurnMessage`'s
  wording plus the brain's current plan and standing orders. About 1.5K tokens.
- `FakeJevClient` (`jev:fake`): deterministic answers for tests, like `fake:coach`.
- Tests: question shapes, state size, answer mapping, threshold and cooldown logic.

### 2. Reflex loop in the adapter (one to two days)

- `adapter/src/reflex.ts`: `Reflexes` per side, started by `main.ts` next to the `Coach` when
  the spec has `+jev` or is `jev:jev`. Ticks on each `state` frame while the round is live.
  - Plan: a knob is sent only when it moves a full level from what is in force, and only within
    a band around the brain's baseline (±0.25), so the brain keeps authority. Range and
    reaction change on a confident majority over the last 3 ticks (hysteresis, no churn).
  - Read: `predict` when the top probability ≥ threshold (default 0.6, a setup setting) and no
    read is pending; the game's existing `read` events score it.
  - Gates: `coach.turn("reflex:<gate>")` when a `noul` ≥ 0.7, cooldown 4 s per gate.
  - Caption: templated when the plan or read changes, at most one every 2 s, so the HUD stays
    readable.
- `Coach` changes: a `cadenceMs` of 0 means event-driven only (round start, knockdown, health
  swing, gates); a new reply field *orders* (one line of standing orders, `say`-sized) stored
  and fed to Jev's state; `stats()` gains reflex counters (ticks, usd, reads, gates fired).
- Game side: plan frames get an optional `source: "reflex"` so `coach_controller.gd` can draw a
  reflex chip (⚡) distinct from the brain's plan chips. No other GDScript change.
- Budget: one cap per side covers both; Jev at the default 2 Hz for a three-round match is
  roughly 200 calls × 1.9K tokens ≈ $0.02 (the first live match measured $0.019 at 4 Hz).

### 3. Setup page, CLI, logs (one day)

- `--p1 jin=anthropic:claude-opus-5-5+jev`; setup page: a *Reflexes: Jev* toggle per corner,
  the read and gate thresholds and the reflex rate (2 or 4 Hz) in the advanced settings, the
  `jev` key in the keys panel, `jev` in `PROVIDERS` with a static model list.
- Logs: `<side>.reflex.jsonl` (tick, state tokens, every answer with its probabilities, what was
  sent); `battle.json` splits the side's cost into brain and reflex and records reads precision.
- Results and Elo: the hybrid spec is its own row; the results page shows brain turns, reflex
  ticks and the gate count.

### 4. Self-coding mode with reflexes (half a day)

In `script` mode the brain's `set_policy` gains an `orders` field and may rewrite the gate
criteria text; during the round Jev runs only the read and the gates (the in-game rules engine
already executes the plan). After each round the brain sees Jev's gate and read record in the
round summary and rewrites both the rules and the orders: System 2 reprogramming System 1 from
what actually happened.

### 5. Evaluation (half a day)

A round robin on fixed seeds and the Boxing Ring, two legs with corners swapped:
Haiku coach, Opus coach, Jev alone, Haiku+Jev, Opus+Jev. Compare Elo, reads precision, cost per
side, brain turns per match and average plan age. Keep the tournament JSON and write the
result into this file.

## Risks

- **Calibration on game state is unproven.** Nobody has published Jev on anything like this;
  phase 0 exists to find out cheaply. Wrong reads cost a miss on screen, wrong gates cost an
  unnecessary brain turn, so the thresholds are the safety margin.
- **Early access.** DigitalOcean serves it today; rate limits and versions (`typesafe-jev-1.13.0`)
  may move. Pin the model id in the price table and the client.
- **Plan churn.** Four decisions a second can thrash the fighter; the level step, the band
  around the baseline and the hysteresis are there to stop it. Tune on the logs.
- **Two writers of one plan.** The brain's `set_plan` resets the baseline and the band; a reflex
  nudge never overrides a knob the brain set in the last 2 s.
- **Spend.** Jev is cheap; the brain's turns are not, and a gate that fires too often is a
  frontier model at 2 s cadence again. The cooldown and the per-side cap bound it.

## Status (2026-10-31)

Built, on the `jev` branch:

- `adapter/src/jev.ts`: the Jev client (DigitalOcean's `systemone` endpoint, `$JEV_URL` to
  point elsewhere), the twelve-question set, the state block, the answer mapping, the fake.
- `adapter/src/reflex.ts`: the reflex loop (ticks on state frames, the level step and the band
  around the brain's plan, the 2 s hold after the brain sets a plan, three-tick majorities for
  the choices, the read threshold and one read at a time, the gates with a 4 s cooldown and one
  brain turn however many fire together, templated captions with no brain, the per-tick log,
  the record the brain reads), and the spec grammar (`+jev`, `jev:jev`, `+fake`, `jev:fake`).
- `coach.ts` / `prompt.ts`: the `orders` tool, the reflexes paragraph in both system prompts,
  `set_policy.orders`, the reflex record in every prompt, cadence 0 for event-driven brains,
  the read ledger so each mind's reads are scored apart.
- `main.ts`: `--reflex-rate`, `--read-threshold`, `--gate-threshold`, a 6 s brain cadence by
  default with reflexes, `reflexes` in `live.json` and `battle.json`.
- Setup page and server: the *Reflexes: Jev* toggle per corner, `jev` as a provider (reflexes
  alone) and as a key, the reflex settings, the reflex line on the live board, reflex costs in
  results and the Elo table, `<side>.reflex.jsonl` links; `--link-port` so two setup servers
  can play side by side. Tournaments carry the reflex settings and count reflex costs.
- Game: a `plan` frame with `source: "reflex"` draws its chips with a bolt (⚡).
- `adapter/src/probe.ts`: phase 0, runnable against the fake or Jev.
- Tests: 70 in the adapter (22 new), 45 checks in `tests/coach_test.gd`.

Live Jev runs through TypeSafe's API (a console.typesafe.ai key in `infra/keys/jev.key`,
`JEV_URL=https://api.typesafe.ai/v1/systemone` in the environment of the setup server or the
CLI; the DigitalOcean key failed on tier, see Keys above). Step 2, the probe, ran on 2026-10-31
and passes, narrowly (below). Still to do:

3. The round robin: Haiku, Opus, `jev:jev`, `anthropic:claude-haiku-5-5+jev`,
   `anthropic:claude-opus-5-5+jev` on fixed seeds, two legs, with the read threshold at 0.7 and
   the gate threshold at 0.8 (the probe's numbers, not the defaults).

### Token cuts (2026-10-31, after the first live match)

The first live match (Jin Haiku against Kenji Haiku+jev, seed 12, Kenji 2–0) spent $0.019 on
the reflexes against $0.008 on the brain: 212 ticks at about 2,600 tokens each, and a third of
the 4 Hz ticks skipped because Jev's 286 ms answer was still in flight. Three cuts, all pushed:

- The default rate is 2 Hz (`--reflex-rate 2`; 4 is still there). Halves the calls for little
  loss: the brain turns every 6 s and the knobs move a quarter step at a time anyway.
- The state block carries only the newest 8 events since the brain's last turn; the full list
  grew for seconds and every tick resent it.
- The five knob questions lost their repeated judging sentence; one line at the end of the
  state says it once. The questions are still four fifths of a call (about 850 tokens by
  character count): Jev needs its criteria spelled out, so they stay.

Re-probe with the trimmed text: 1,870 input tokens a call (from 1,979; the probe's states were
short already), precision 41% at 0.6 and 45% at 0.7 (from 39% and 44%), latency unchanged.
Expected cost of a three-round match's reflexes: about $0.007 (from $0.019).

### Phase 0 with Jev (2026-10-31, model jev-1.14.0 through TypeSafe)

400 logged turns from 12 matches, 355 reads judged against what the opponent then did within
6 s. Latency p50 259 ms, p95 374 ms (the first call of a session took 2.7 s, a cold start);
1,979 input tokens a call; $0.033 for the whole probe.

| threshold | reads fired | came true | precision | coverage of turns |
|---|---|---|---|---|
| 0.5 | 182 | 67 | 37% | 46% |
| 0.6 | 125 | 49 | 39% | 31% |
| 0.7 | 86 | 38 | 44% | 22% |
| 0.8 | 54 | 23 | 43% | 14% |

Gates at 0.7: plan failing on 23% of turns, window open on 25%, pattern changed never. By word:
super 29/47, 236K 37/80, sweep 36/87, 236P 11/34, uppercut 10/38; 623P, jump, reversal and
throw never came true, on samples of one to four. The LLM coaches' reads in the same logs:
Haiku 1/12, GPT-5.4 mini 5/10, the fake coaches 36/88 together.

So at 0.6 Jev matches the fake coaches (39% against 41%) and beats the real brains (27%); at
0.7 it beats both at 44% while still reading a fifth of all turns. The go/no-go passes, with
two corrections to the defaults: read at 0.7, not 0.6, and raise the gate threshold to 0.8,
because the two health gates fire on a quarter of turns at 0.7 (the 4 s cooldown caps the
damage, but every wake is a brain call). Two caveats: most judged turns come from fake-coach
matches, whose fighters follow scripted patterns, and the fake's own probe (next section) scored
28% on the same kind of logs, so part of Jev's margin is the base rate of repeated attacks. The
round robin against real brains is the real test.

### Phase 0 with the fake (pipeline check only)

1,247 logged turns from 18 matches, 362 reads judged against what the opponent then did within
6 s. The fake's read (the opponent's most repeated recent attack) came true 28% of the time at
every threshold it clears (it answers 0.72 or nothing), against 8% to 50% for the LLM coaches'
reads in the same logs on tiny samples. Gates at 0.7: plan failing 21% of turns, window open
19%, pattern changed 15%. About 1,285 input tokens a call.

### Phase 5 pilot with the fake

Four entrants, one leg, the Boxing Ring, seed 11, brains at a 2 s cadence, reflexes at 4 Hz:
Jin and Kenji with `fake:coach`, Jin with `fake:coach+jev`, Kenji with `jev:fake`. Six matches,
none failed, about two and a half minutes each.

| Entrant | Pts | Rounds |
|---|---|---|
| Kenji · fake:coach | 3 | 6–1 |
| Jin · fake:coach | 2 | 5–2 |
| Kenji · jev:fake | 1 | 2–4 |
| Jin · fake:coach+jev | 0 | 0–6 |

What the pipeline did, from `battle.json` and `<side>.reflex.jsonl`: 222 to 386 ticks a side at
60 ms each (the fake's delay), 2 to 102 frames skipped while a call was in flight, no errors;
the reflex-only corner nudged the plan 49 to 59 times a match and read 36 of 53 (the fake's read
is the opponent's most repeated attack, and fake coaches repeat); the hybrid corner nudged 9 to
18 times (the fake brain sets a plan every 2 s, so the 2 s hold was on most of the time) and its
gates woke the brain 18 to 28 times a match (plan failing and window open; pattern changed
never cleared 0.7). Every brain prompt after a tick carried the reflex record line. The reflex
corners lost: the fake's knob heuristics (block down to 0.25 when the opponent is not landing
hits, aggression up when behind) are placeholders, not a policy, and say nothing about Jev.
