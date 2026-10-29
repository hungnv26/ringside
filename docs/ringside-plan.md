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

Later modes (not in phase 1): the *beat fighter* (discrete beats where both models pick a move)
and the *self-coding fighter* (the model rewrites its fighter's behaviour between rounds).

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
3. **Presentation.** Model captions, a thinking indicator, match recording to video.
4. **Second modes.** Beat fighter, self-coding fighter, tournaments.

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

## Conventions (carried from the user's other games)

- HUD shows only real, working data; no neon, strong glow or moving lights.
- No in-game setup screens: matches start from the command line now and from a setup page
  in phase 2.
- Keep 3D Fighter's credits and licences. Our own content is CC BY 4.0 like theirs.
