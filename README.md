# Ringside

A one-on-one 3D fighting game where nobody holds a controller: each fighter is coached by an
AI model. The fight runs at 60 frames a second in the game; the model sits ringside, watches,
and changes its fighter's game plan every couple of seconds (range, aggression, what to block
and punish, which moves to go for), the way Outpost War's sides are commanded by models.
Three ways to play, picked per match: the **coach** adjusts its fighter's plan every couple
of seconds; the **self-coding fighter** writes a rule set before the match and rewrites it
after every round from what actually landed, with no model calls during a round; the **beat
fighter** pauses the game every beat until both models have chosen their next moves.
Working name. Plan and protocol: [docs/ringside-plan.md](docs/ringside-plan.md).

Built on [3D Fighter](https://github.com/GabrielGonHo/3d-fighter) (MIT code, CC0 assets): its
fighters, stages, frame data and CPU opponent are the executor the coaches drive. Everything
below "3D Fighter" is its original README and still applies.

## Run a coached match

Requires Godot 4.7 (`godot` on the PATH) and Node 24. Assets are in Git LFS: `git lfs pull`
after cloning, then open the project once (or `godot --headless --path . --import`).

```bash
cd adapter && npm install
npm run setup            # the setup page: http://127.0.0.1:8798
```

The **setup page** is where matches are set up (no setup screens in the game): a fighter and
the model that coaches it for each corner, the provider keys, stage, seed, cost cap, turn pace
and thinking effort. *Start match* opens the game window; the page shows the round, both
health bars, each coach's caption, plan, turns and cost, and the event feed, then keeps every
result with links to the transcripts, and an Elo table by model. *Record the match to video*
saves `match.mp4` next to the logs (Godot's movie writer plus ffmpeg).

From the command line instead:

```bash
node src/main.ts --p1 jin=fake:coach --p2 kenji=fake:coach --quit        # no key, no cost
node src/main.ts --p1 jin=anthropic:claude-haiku-5-5 --p2 kenji=openai:gpt-5.4-mini --stage rooftop --cap 0.5
```

The adapter starts the game in coach mode, coaches both sides until the match ends, prints the
result and the log folder (`battle-logs/`), and closes the game. Keys go in
`infra/keys/<provider>.key` (the setup page saves them there); see
[adapter/README.md](adapter/README.md) for every flag, the key lookup and the log layout. The
game alone: `godot --path . -- --coach=ws://127.0.0.1:8797 --p1=jin --p2=kenji --stage=rooftop --seed=7`.

## Checks

```bash
godot --headless --path . -s res://tests/coach_test.gd     # coach mode (25 checks)
godot --headless --path . -s res://tests/sim_test.gd       # 3D Fighter's regression suite
cd adapter && npm test && npm run typecheck                # the adapter and the setup page (33 tests)
```

## What was added

- `scripts/ai/coach_controller.gd`: the CPU fighter with a coach; plans, queued moves, captions,
  the self-coding rules engine and the manual (beat) mode.
- `scripts/coach/coach_link.gd`: the WebSocket link to the adapter; observation frames and events.
- `GameState.Mode.COACH`, `-- --coach=...` on the command line, both sides coached in `FightManager`.
- `adapter/`: the coaches, the model calls (Anthropic, OpenAI, OpenRouter, Ollama, a fake), logs.
- `adapter/src/setup.ts` + `adapter/setup/index.html`: the setup page, results and Elo.

---

# 3D Fighter

[![tests](https://github.com/clintcan/3d-fighter/actions/workflows/tests.yml/badge.svg)](https://github.com/clintcan/3d-fighter/actions/workflows/tests.yml)

A one-on-one 3D fighting game inspired by Street Fighter and Tekken, built in **Godot 4**.
Its signature is a **dynamic action camera** that orbits and dollies in on every big hit.

![3D Fighter key art](assets/ui/splash.png)

## Features

- **7 fighters**, each with normals, motion-input specials, a super and a distinct CPU personality (design notes in [docs/characters](docs/characters/README.md)):
  - **Kenji**: zoner;
  - **Rhea**: rushdown;
  - **Brutus**: punisher;
  - **Valka**: grappler with an unblockable command grab;
  - **Jin**: Tae Kwon Do kicker who controls kick range;
  - **Mira**: street brawler who powers up with Lakas Stance (Focus) until her rushes hit like a typhoon.
- **Outfits** that fit each style: a karate gi with headband, a Tae Kwon Do dobok, kickboxing gear, a wrestling singlet with knee pads and boots, a brawler's tank top and work pants, a street fighter's zip-up, track pants and sneakers. Woven fabric textures, stitched hems and skin detail hold up in close-ups. Mirror matches get alternate colours.
- **8 stages**: Boxing Ring, Dojo, Rooftop, Temple, Beach, Night Market, the Express (a fight on the roof of a speeding train) and the Kowloon Courtyard, where the sun rises round by round, the neighbours come out to watch and jets roar in low overhead. Each has its own music and ambient life (crowds, flames, smoke, rain, neon, passing trains, pigeons).
- **Modes**: Vs CPU, Arcade (ladder, scoring, shadow boss), local 2-player Versus, **Online** (rollback netcode, LAN discovery, join by IP, or an internet lobby server with rooms and spectating), Training (frame data, input display, record/playback, and combo trials with a "show me" demo) and a Demo of two CPU fighters on a random stage. Finished matches are saved as **replays** (pause, frame step, slow motion, seeking).
- **Fighting-game systems**: super meter with cinematic super freezes, counter hits, combos, juggles, wall splats and rope bounces at the stage edge, throws and throw breaks, high/mid/low blocking, and Tekken-style sidesteps.
- **Engine**: a deterministic 60 Hz simulation (verified identical on Windows and Linux) with a headless regression test suite.

## Screenshots

| | |
|---|---|
| ![Jin's Tornado Kick on the beach](docs/screenshots/beach.jpg) | ![Jin's Hurricane Kicks super](docs/screenshots/jin_super.jpg) |
| ![Temple stage](docs/screenshots/temple.jpg) | ![Super flash](docs/screenshots/super.jpg) |
| ![Earthquake in the dojo](docs/screenshots/dojo.jpg) | ![Thunder Valkyrie on the rooftop](docs/screenshots/rooftop.jpg) |
| ![Character select](docs/screenshots/character_select.jpg) | ![Stage select](docs/screenshots/stage_select.jpg) |

## Controls

| | Keyboard (P1) | Gamepad |
|---|---|---|
| Move / jump / crouch | W A S D | Left stick / D-pad |
| Light / Heavy Punch | U / I | X / Y |
| Light / Heavy Kick | J / K | A / B |
| Sidestep | L | RB |
| Pause & move list | Esc | Start |

- **Specials** use motion inputs (for example ↓↘→ + P), and a full super meter enables ↓↘→↓↘→ + P/K. Each fighter's moves are listed in the pause menu.
- **Player 2** uses the arrow keys with numpad 4/5 (punches), 1/2 (kicks) and 6 (sidestep), or a second gamepad.
- **Online:** one player hosts; on the same network the other picks the game from the list, or joins by address (UDP port 7777; forward it on the host's router to play over the internet). Both players need the same build. Connections are encrypted, and both screens show a 6-digit security code to compare.
- **Internet lobby** (Online → Internet Lobby): connect to a 3D Fighter lobby server, open a room or join one from the list or by its 6-letter code, no port forwarding needed (the server punches through NATs, or relays the encrypted traffic). Rooms can allow spectators, who watch live with a short delay and can send reactions.
- **Remapping:** every key and gamepad button can be changed per player in **Options → Controls**, which shows a controller diagram. The triggers can be bound too.

## Run from source

Requires **Godot 4.7** with a Vulkan-capable GPU.

```bash
godot -e --path .   # open in the editor
godot --path .      # run the game
```

## Tests

```bash
godot_console --headless --path . -s res://tests/sim_test.gd   # exit code 1 on failure
```

## Build releases

This needs the Godot 4.7.2 export templates for Windows, macOS and Linux, plus Python 3.

```bash
python tools/build_release.py all                     # Windows + macOS + Linux -> dist/
python tools/build_release.py windows linux           # any subset
python tools/build_release.py all --test              # run the tests first, stop on failure
python tools/build_release.py all --version 0.3.0 --test --notarize   # full release
```

The script produces three archives:

| Output | Contents |
|---|---|
| `dist/3DFighter-v<ver>-windows.zip` | Single exe plus README; smoke-tested |
| `dist/3DFighter-v<ver>-macos.zip` | Universal `.app`, signed with Developer ID; `--notarize` notarizes and staples it |
| `dist/3DFighter-v<ver>-linux.tar.gz` | x86_64 binary plus README; smoke-tested in WSL when available |

Mac signing reads its credentials from `%USERPROFILE%\AppleDeveloper`, which stays outside the repo. Use `--no-sign` for a local unsigned build.

## Project layout

```
scripts/   gameplay (fighter, AI, camera, FX, UI, arcade, training)
scenes/    menus, fight scene, generated stages
data/      characters and moves (generated; edit tools/build_movesets.gd)
tools/     generators (stages, animations, movesets, key art) and build_release.py
tests/     headless simulation tests
```


## Credits

All third-party assets in the game are CC0, credited in [assets/CREDITS.md](assets/CREDITS.md) (the logo is lettered with the Permanent Marker font, Apache 2.0, kept in `tools/fonts/`):

- **Characters and animations:** [Quaternius](https://quaternius.com).
- **Skies and textures:** [Poly Haven](https://polyhaven.com).
- **Sounds and announcer:** [Kenney](https://kenney.nl).
- **Music and voices:** [OpenGameArt](https://opengameart.org) artists.

Made with [Godot Engine](https://godotengine.org).

## License

© 2026 Clint Christopher Canada.

- **Code:** [MIT License](LICENSE).
- **Original assets** (stages, generated animations, portraits, key art and logo, synthesized sounds): [CC BY 4.0](LICENSE-ASSETS.md).
- **Third-party assets:** keep their own licenses (CC0; the logo tool's font is Apache 2.0); see [assets/CREDITS.md](assets/CREDITS.md).
