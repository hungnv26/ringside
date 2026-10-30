# Ringside adapter

Links the language models to the game. One Coach per side watches the fight over a WebSocket
and adjusts its fighter's game plan every couple of seconds (docs/ringside-plan.md). Node 24
runs the TypeScript directly; `npm install` once.

## The setup page

```bash
npm run setup        # http://127.0.0.1:8798 (--port N, or $PORT)
```

`src/setup.ts` serves `setup/index.html` and a JSON API (`/api/setup`, `/api/models?provider=`,
`POST /api/key`, `POST /api/match`, `POST /api/stop`, `/api/status`, `/api/results`,
`/api/log?id=&file=`, `/api/captures?id=`). It starts a match by spawning `main.ts` with
`--log battle-logs/<id> --quit`, and reads that folder's `live.json`, which `main.ts` rewrites
every second and on every event. Bound to 127.0.0.1 only.

Tournaments (`src/tournament.ts`): `POST /api/tournament` with `{name, entrants: [{fighter,
spec}], legs: 1|2, stage: <id>|"rotate", ...the match settings}` schedules a round robin and
plays it through the same runner, one match after another (two seconds between matches);
`/api/tournament?id=` returns the fixtures and standings, `/api/tournaments` lists them,
`POST /api/tournament/stop` ends the match in progress and skips the rest. `/api/status`
carries `tournament` while one runs, and `POST /api/match` is refused meanwhile. Each
tournament is saved as `battle-logs/tournaments/<id>.json`; one the server was restarted
under is left as it was (its unplayed fixtures are not resumed). A match that exits without a
`battle.json` is marked failed and the tournament goes on.

## What a coach can do

Coach mode's tools are `set_plan`, `queue`, `say` and `predict` (a read: one of the opponent's
move inputs or jump, throw, super, fireball, low, overhead, sweep, reversal, uppercut; the game
answers with a `read` event when it comes true within 6 s, expires or is replaced, and the
HUD shows CALLED IT). The first line of every reply is the coach's *corner talk*, sent to the
game as a `talk` frame and shown under its caption. `stats()` and `live.json` carry
`lastTalk` and `reads {made, right}` per side.

## Run a match

```bash
cd adapter
node src/main.ts --p1 jin=anthropic:claude-haiku-5-5 --p2 kenji=openai:gpt-5.4-mini --stage rooftop
node src/main.ts --p1 jin=fake:coach --p2 kenji=fake:coach --quit     # no key, no cost
```

The adapter listens on `ws://127.0.0.1:8797`, launches the game
(`godot --path <repo> -- --coach=ws://127.0.0.1:8797 --p1=jin --p2=kenji --stage=rooftop --seed=N`),
waits for the game's `hello`, then coaches both sides until `match_end`, prints the result and
the log folder, sends `end` to the game and exits 0. Ctrl-C ends the game too.

| Flag | Default | Meaning |
|---|---|---|
| `--p1 fighter=provider:model`, `--p2 ...` | `jin=fake:coach`, `kenji=fake:coach` | The fighter id (jin, kenji, rhea, brutus, valka, mira, lian) and the model coaching it |
| `--stage name` | `rooftop` | ring, dojo, rooftop, temple, beach, market, train, courtyard |
| `--seed N` | random | The match seed (the simulation is deterministic for a seed and the same inputs) |
| `--cap USD` | `1` | Cost cap per side; at the cap the side keeps its last plan |
| `--cadence ms` | `2000` | Wall time between a coach's turns while the round is live |
| `--effort low\|medium\|high` | `low` | Thinking effort for Claude and OpenAI reasoning models |
| `--port N` | `8797` | The link's port |
| `--no-launch` | | Do not start the game; wait for one to connect (`godot --path . -- --coach=ws://127.0.0.1:8797 ...`) |
| `--godot path` | `godot` (or `$GODOT`) | The Godot 4.7 binary |
| `--quit` | | Pass `--quit-after-match` to the game |
| `--log DIR` | `battle-logs/<time>-<p1>-vs-<p2>` | The exact log folder (the setup page chooses it); `live.json` in it is the status the page polls |
| `--window 720p\|900p\|1080p\|1440p\|fullscreen` | `1080p` | The game window for this match, in screen points (3840×2160 pixels for 1080p on a 2× Retina screen); the 3D is drawn at the window's own resolution; a size that does not fit the screen falls back to the largest that does |
| `--graphics high\|showcase` | `high` | Picture quality: High draws the 3D at 1080p and upscales it (MetalFX on a Mac) with ambient occlusion, indirect light and reflections, 74–92 fps on an M1 Pro; Showcase draws at the window's full resolution and adds global illumination, about 20–27 fps live, meant for `--record` |
| `--mode coach\|script` | `coach` | coach: a turn every cadence; script: the self-coding fighter (a policy of rules before the match and after each round) |
| `--record FILE.mp4` | | Record the match: Godot's movie writer at a fixed 60 fps, then ffmpeg encodes the .mp4 after the game closes (needs `ffmpeg` on the PATH) |
| `--capture DIR` | | The game saves a screenshot every 10 s of the fight and one of the result to DIR |

Models: `anthropic:<model>` (Messages API, prompt caching, `output_config.effort`),
`openai:<model>` (Responses API for `o*`, `gpt-5*`, `gpt-6*`; chat completions otherwise),
`openrouter:<vendor/model>`, `ollama:<model>` (local, `$OLLAMA_URL`, no thinking), `fake:coach`
(deterministic, for tests and smoke runs).

## Keys

`infra/keys/<provider>.key` under the repo root (mode 600, gitignored). If a key is not there,
the adapter looks in `$RINGSIDE_KEYS_DIR/<provider>.key`, then in
`../outpost-zero/infra/keys/<provider>.key` (the same files Outpost War uses, so a key saved
there serves here), then in `<PROVIDER>_API_KEY` in the environment. No key is needed for
`ollama` or `fake`.

Prices for the cost cap and the logs: `design/model_prices.json` (USD per million tokens, the
same table as Outpost War's).

## Logs

`battle-logs/<time>-<p1>-vs-<p2>/` (gitignored):

- `battle.json`: setup (fighters, models, stage, seed, cap, cadence, effort), the result and
  each coach's totals (turns, tokens, cost, average answer time, plans applied and refused,
  errors, last caption, plan in force at the end).
- `p1.md`, `p2.md`: the system prompt once, then every turn: what triggered it (cadence,
  round_start, knockdown, health_swing), the prompt the model read, its reply and tool calls,
  the game's answers, answer time, tokens, cost.
- `p1.jsonl`, `p2.jsonl`: the same turns, one JSON line each.

## Checks

```bash
npm test            # 48 tests: prompt text, plan validation, the fake, the link over a socket, coach cadence/cap/errors, logs, CLI, the setup API, modes, tournaments, corner talk and reads
npm run typecheck
```

## Layout

```
src/types.ts   the protocol frames and the model-call shapes
src/link.ts    WebSocket server; parses the game's frames, sends plan/queue/say/end
src/models.ts  provider calls (ported from Outpost War's gateway), keys, prices, cost
src/fake.ts    the fake model
src/prompt.ts  system prompt, turn message, tools, plan validation
src/coach.ts   one side's coach: cadence, triggers, tool calls to frames, budget
src/log.ts     battle logs
src/main.ts    CLI, game launch, status, result
src/setup.ts   the setup page's server: roster, keys, models, the match runner, results, Elo
src/tournament.ts  round robins: schedule, fixtures, standings, the tournament runner
```
