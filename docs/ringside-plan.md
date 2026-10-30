# Ringside: AI models coach the fighters

Working name. Ringside is a one-on-one 3D fighting game where neither fighter is played by a
human: each side is coached by a language model, the way Outpost War's sides are commanded
by one. The fight itself runs at 60 Hz in the game; the model sits ringside and changes its
fighter's game plan every couple of seconds. Started 2026-10-30 as a fork of
[3D Fighter](https://github.com/GabrielGonHo/3d-fighter) (MIT code, CC0 Quaternius
animations; see LICENSE, LICENSE-ASSETS.md and assets/CREDITS.md, which stay).

## Why a coach, not a player

A model answers in 2 to 6 seconds; a jab is 10 frames. So the model cannot press buttons.
Instead the game's own CPU fighter (`scripts/ai/ai_controller.gd`) executes at frame level and
the model tunes what it already exposes: preferred range, aggression, block and punish
chances, reaction delay, and the weights of its options (poke, string, rush, dash, jump,
throw, grab, fireball, sidestep, wait, retreat, approach). The coach can also queue a specific
move or combo and say a short caption that the HUD shows at its fighter's corner.

A later mode (phase 4): the *self-coding fighter* (the model rewrites its fighter's behaviour
between rounds). A *beat fighter* (the game paused every beat for both models to pick a move)
was built and removed on 2026-10-30: a fight that stops every second or two is dull to watch,
and the models mostly queued jabs and one-frame blocks.

## Phases

1. **Coach controller and adapter link** (this phase). `CoachController` in the game; a
   `coach` match mode started from the command line that connects to an adapter over
   WebSocket; the adapter runs one Coach per side against a model (Anthropic, OpenAI,
   OpenRouter, Ollama, or a fake model for tests), logs every turn and caps the cost. Done
   when a full best-of-three match runs end to end with the fake model, the headless test
   covers the controller, and one real match has been played.
2. **Setup page** (built 2026-10-30). `adapter/src/setup.ts` on :8798 serves
   `adapter/setup/index.html`: a fighter and model per corner (model lists from each
   provider), keys saved to `infra/keys`, stage, seed, cap, cadence, effort; starts one match
   at a time by spawning `main.ts --log <folder> --quit`, polls the folder's `live.json`
   (phase, state, coaches' stats, last events, result) and shows the adapter's console;
   results from `battle-logs/*/battle.json` with transcript links, screenshots, and Elo per
   model (K 32 from 1000, draws half).
3. **Presentation** (built 2026-10-30). Name plates read "Jin · claude-haiku-5-5" (the
   adapter's `models` frame), a "COACH THINKING" mark shows above a side's caption while its
   model answers (`thinking` frames around every call), and *Record the match to video* on
   the setup page runs the game with Godot's movie writer (`--write-movie`, fixed 60 fps,
   MJPEG + wav) and encodes `battle-logs/<id>/match.mp4` with ffmpeg once the game closes;
   the page plays it and the results link to it. A slow machine renders slower than real
   time while recording, which slows the game, not the coaches.
4. **Second modes and tournaments** (built 2026-10-30). Modes are picked per match on the setup page
   (`--mode coach|script`, sent to the game as a `mode` frame):
   - **Self-coding fighter** (`script`): the model takes one turn before the match and one
     after every round, with `set_policy`: a plan plus up to 12 rules `{name, when, do, weight}`.
     `when` tests range (close/mid/far), what the opponent is doing (idle, attacking,
     recovering, blocking, knocked_down, jumping, stunned), corners, a full meter and health
     shares; `do` is up to four named moves. In the game `CoachController` checks the rules
     every 10 frames when the fighter is free, picks one matching rule by weight (45-frame
     rest per rule) and queues its moves; with no match the fighter plays its own style under
     the plan. The round-end event carries a summary per side (every attack with hit, counter,
     blocked and whiffed counts, throws, knockdowns, health left, the last rule that fired),
     which is the whole of the next prompt. No model calls during a round.
   - **Tournaments** (`adapter/src/tournament.ts`): a round robin between 2 to 8 entrants (a
     fighter and its model), each pair once or twice with corners swapped, stage fixed or
     rotating, the match settings shared; played one match after another through the setup
     page's runner and saved in `battle-logs/tournaments/<id>.json`. Standings: a win 1, a draw
     ½, ties on round difference, rounds won, then cost. A failed match is recorded and skipped;
     *Stop tournament* ends the match in progress and skips the rest. Not built: brackets.

## Parts

```
adapter (Node, TypeScript, :8797)                game (Godot 4.7)
  main.ts   CLI: sides, stage, cap, launch godot   GameState: --coach=ws://... --p1 --p2 --stage --seed
  link.ts   WebSocket server, protocol below       scripts/coach/coach_link.gd  (client, observation,
  coach.ts  one Coach per side: cadence, prompt,       applies plans, captions)
            tools, budget, log                     scripts/ai/coach_controller.gd (extends AIController)
  models.ts provider calls (copied from Outpost     FightManager: Mode.COACH, both sides coached
            War's gateway), prices, keys
  fake.ts   deterministic fake model
  log.ts    battle-logs/<id>/<side>.md + .jsonl
```

Keys: `infra/keys/<provider>.key` (600, gitignored); if absent, the adapter also looks in
`$RINGSIDE_KEYS_DIR` and `../outpost-zero/infra/keys`. Prices: `design/model_prices.json`.

## Protocol (game ⇄ adapter, JSON text frames over one WebSocket)

The game connects to the adapter (`--coach=ws://127.0.0.1:8797`). Every frame is one JSON
object with a `type`. Sides are `"p1"` and `"p2"`.

Game → adapter:

- `hello` `{type, version, p1: FighterInfo, p2: FighterInfo, stage, rounds_to_win, round_seconds, seed}`.
  `FighterInfo = {id, name, archetype, max_health, moves: [{input, name, startup, active,
  recovery, damage, level, notes}]}` where `level` is high|mid|low|overhead|throw and notes
  mention launcher, knockdown, invincible, projectile, super, command grab.
- `state` every 15 ticks (4 per second) while the round is live, and once at round start:
  `{type, tick, round, timer, wins: [p1, p2], p1: Side, p2: Side, distance}`.
  `Side = {health, max_health, meter, max_meter, state, move, x, cornered, plan_age_ticks,
  recent: [{input, name, outcome}] }` where `state` is the fighter state name in lower case
  (idle, walk_fwd, attack, blockstun, knockdown...), `move` the current attack's input or
  null, `cornered` true when pinned against the edge, and `recent` the side's last 8 attacks
  newest last with `outcome` hit|counter|blocked|whiffed|pending.
- `event` `{type, tick, event, ...}` with `event` one of `round_start {round}`,
  `hit {attacker, defender, input, name, result, damage, combo}`, `throw {attacker, defender}`,
  `knockdown {side}`, `super {side, name}`, `round_end {winner: p1|p2|null, reason}`,
  `match_end {winner, wins, reason}`.
- `applied` `{type, side, plan_id, ok, error}` after a plan or queue message was applied.

Adapter → game:

- `plan` `{type, side, plan_id, plan: Plan}` where every field is optional and unspecified
  fields keep their current value:
  `Plan = {aggression: 0..1, range: close|mid|far|number (metres), block: 0..1, punish: 0..1,
  anti_air: 0..1, reaction: fast|normal|slow, pressure: 0..1, options: {poke, string, rush,
  dash, jump, throw, grab, fireball, ground_special, sidestep, wait, retreat, approach,
  stance, reversal: 0..3}}`. Option weights multiply the character's own personality weights.
- `queue` `{type, side, plan_id, moves: [string]}`: inputs to do next, in order, once the
  fighter is actionable: a move input from its list (`LP`, `2HK`, `6HK`, `236K`, `236236K`),
  `throw`, `dash`, `backdash`, `jump`, `sidestep`, `block N` (hold back N ticks), `wait N`.
  Unknown entries are refused in `applied.error` and the rest still run.
- `say` `{type, side, text}`: a caption of at most 60 characters at the side's corner.
- `end` `{type, reason}`: the game quits (the adapter sends it after `match_end`, or on a
  cost cap).
- `models` `{type, p1, p2}`: each side's "provider:model", for the HUD's name plates.
- `thinking` `{type, side, on}`: the side's coach is waiting for its model (HUD mark).
- `mode` `{type, mode: coach|script}`: sent after hello.
- `policy` `{type, side, plan_id, plan?, rules?}`: self-coding mode; answered with `applied`.
- `talk` `{type, side, text}`: the coach's corner talk (the first line of its reply, up to 140
  characters), shown under the caption at its corner for seven seconds.
- `predict` `{type, side, plan_id, what}`: a read on the opponent: one of their move inputs or
  jump, throw, super, fireball, low, overhead, sweep, reversal, uppercut. One read per side at a
  time; a new one replaces the old, which counts as a miss. Answered with `applied`.

Game → adapter, in addition: `round_end` carries `round` and `summary {p1, p2}` (attacks by input with hit/counter/blocked/
whiffed counts, `totals`, throws, knockdowns, `supers {used, landed}`, `reads {made, right}`,
health_left, max_health, rule_fired_last); and `read` `{side, what, right, actual}` when a
side's read comes true (within 6 s), expires, is replaced or the round ends.

## Watching (built 2026-10-30)

What the HUD shows at each corner, bottom up: the COACH THINKING mark, the caption (`say`),
*plan chips* for what the last plan or queue frame changed ("block ↑ 0.95", "range → close",
"SUPER QUEUED · block 12 › 236236K", 3.5 s), the *corner talk* line (7 s) and the *read badge*
("CALLED IT · Rising Dragon", 2.5 s). Between rounds a *round card* lists both sides' health
left, hits landed, blocked, whiffed, throws, knockdowns dealt, supers landed and reads called;
coached matches hold the round-over pause 2.5 s longer for it. Plain text only, no glow.

The adapter never blocks the game: a late plan applies when it arrives; a disconnected link
leaves both fighters on their last plan.

## Coach turn (adapter)

Each side's Coach runs independently. Cadence: a turn every 2 s of wall time while the round is
live, plus an immediate turn on `round_start`, on its own `knockdown`, and when either health
bar drops 25% since its last turn (at most one turn in flight per side). A turn sends the
system prompt (rules, its fighter's move list, the opponent's name and archetype, the tools),
then one user message: the latest `state` in words, the events since its last turn, its
current plan, and the result of its last tool calls. Tools: `set_plan`, `queue`, `say`.
The reply's tool calls go to the game as `plan`, `queue`, `say` frames. A reply with no tool
calls is logged and the plan stands.

Prompt caching as in Outpost War (Anthropic cache markers on system+tools; OpenAI Responses
with a stable `prompt_cache_key` per side). Effort: `low` by default (`--effort`), since a
turn is worth less than two seconds. Budget: `--cap USD` per side (default $1); at the cap the
side keeps its last plan and the adapter notes it in the log and on the console.

Logs: `battle-logs/<id>/battle.json` (setup, result, per-side totals), `<side>.md` (every turn:
prompt, reply, tool calls, answer time, tokens, cost), `<side>.jsonl`.

## Window

A coached match opens a 1080p window by default (`--window=720p|900p|1080p|1440p|fullscreen`,
picked on the setup page), sized in screen points: on a 2× Retina screen 1080p is 3840×2160
pixels, and a size that does not fit falls back to the largest that does (a 16" MacBook Pro
gets 3200×1800). The 3D is drawn at the window's own resolution and the player's saved display
settings are not touched. Screenshots and recordings follow the window's pixel size, so a
recording at 1080p on a Retina screen is a 4K movie.

## Conventions (carried from the user's other games)

- HUD shows only real, working data; no neon, strong glow or moving lights.
- No in-game setup screens: matches start from the command line now and from a setup page
  in phase 2.
- Keep 3D Fighter's credits and licences. Our own content is CC BY 4.0 like theirs.
