# Ringside: character movement plan

Scope: how the fighters move. Not bodies, faces, materials, stages, camera or effects (those are
[graphics-plan.md](graphics-plan.md)), and not gameplay. Every change here is cosmetic, runs at
render rate in `Fighter._process` / `FighterModel`, and leaves frame data, hit boxes and the
deterministic simulation untouched.

## Why the fighters look like robots

The bodies are realistic now; the motion underneath them is not. What the code does today:

| What you see | Cause | Where |
|---|---|---|
| Everything in an attack starts and stops at once | The 51 fight clips are built in code from 6–8 whole-body poses; every bone is keyed at the same instants, so hips, shoulders, arms and head move in lockstep with no lead, lag or follow-through | `tools/build_fight_animations.gd` `make_animation` |
| Even, floaty speed through a move | Cubic interpolation between evenly treated keys: no snap into impact, no slow settle, no overshoot | same |
| Moonwalking and gliding | One civilian `Walk_Loop` with the guard pasted on the upper body drives walk forward, walk back (the same clip played backwards), dash and backdash (×2.5) and sidestep (legs walk forward while the body slides sideways) | `fighter.gd` `_animation_request` |
| Feet skate | Clip speed is `walk_speed / 1.5`, a guess at the stride; nothing pins a planted foot. `_keep_feet_above_floor` only lifts the body | `fighter_model.gd` |
| Standing still is dead still | The guard idle is two keys: the pelvis dips 1.5 cm and the spine tips 2° over two seconds | `build_guard` |
| Frozen holds | Block, tech and crouching hitstun show frame 0 of a pose for their whole duration; knockdown holds the last frame of `Hit_Knockback` | `_animation_request` |
| Same flinch for every hit | Two reactions (`Hit_Head`, `Hit_Chest`) for all hits from all directions and strengths; a crouching fighter doesn't react at all | same |
| Hard cuts | One 0.08 s cross-fade for every transition | `BLEND_TIME` |
| Turning on a rail | `face_opponent` sets the facing every tick; the feet never step to follow | `fighter.gd` |
| No weight, no life | No procedural layer at all: no foot IK, no head tracking the opponent (only the eyes), no lean into acceleration, no landing squash, no hair or belt swing | — |

Godot 4.7 has every tool needed for the procedural side (checked in this build):
`TwoBoneIK3D`, `LookAtModifier3D`, `SpringBoneSimulator3D`, `LimitAngularVelocityModifier3D`,
`CopyTransformModifier3D`, `AnimationTree` with blend spaces and state machines.

## One decision first: where better motion comes from

The procedural fixes (phases 1–4) need no new assets. Replacing hand-keyed clips with captured
motion (phase 5) does, and the repo is public with assets under CC0 and CC BY 4.0
(`assets/CREDITS.md`), so the source's licence matters.

| Source | Quality | Licence fit | Cost |
|---|---|---|---|
| A. Improve the code-built clips (overlap, easing, more keys) | Good for attacks; never as natural as capture | Ours | Time only. **Do this regardless** |
| B. CMU Graphics Lab motion capture (boxing, martial arts, walks, falls) | Real human motion, noisy, needs cleanup and retargeting from BVH | Free to use and ship inside a product; may not be resold as data. Fits, credited separately | Free; cleanup time |
| C. Your own capture from video (Rokoko Vision, DeepMotion, Move One free tiers) | Medium; exactly the moves the roster needs | Ours | Filming plus cleanup |
| D. Mixamo | Best ready-made fighting set | Adobe's terms forbid redistributing the motion files; a public repo with the clips baked into `.res` files is a real risk | Free, but **not recommended** for this repo |

**Recommendation: A for everything, B for locomotion, reactions and falls, C later for the
signature specials if A isn't enough.** B and C retarget onto the game skeleton with Godot's humanoid `BoneMap` at import; the UAL
clips need none because they share the skeleton.

## Phases

### Phase 0 · Baseline and checks (1 session)

- Record the same seeded match before any change (Jin vs Kenji, Boxing Ring, `--record`), plus
  a slow-motion clip of each state: walk, back walk, dash, backdash, sidestep, every hit and
  block reaction, knockdown, getup.
- Write `tools/check_motion.gd`, a headless measure the later phases must pass:
  - **foot skate**: a planted sole's horizontal speed while its height is under 2 cm (target
    under 5 cm/s; today's walk will fail it);
  - **held poses**: any state that shows an unchanged pose for more than 10 frames;
  - **reach unchanged**: each attack's striking limb at `animation_impact` stays within 3 cm of
    today's, so the art still matches the hit boxes.
- `sim_test` and `coach_test` keep passing at every phase.

### Phase 1 · Footwork and the living stance (2–3 sessions, the biggest single win)

- **Stance idle per archetype**: a weight shift from foot to foot, a breathing rise in the
  chest, hands drifting in the guard, a small bounce for the boxers and rushdown fighters, a
  heavy settle for Brutus. Two or three variants per fighter, cross-faded on a timer.
- **Real footwork clips** instead of the civilian walk: step forward and step back in guard
  (lead foot first forward, rear foot first back), side steps left and right for the sidestep,
  a push-off lunge for the dash, a hop for the backdash, each authored for its own direction.
- **Stride matching**: playback speed from the fighter's actual ground speed over the clip's
  measured stride, so feet move as far as the body does.
- **Foot locking**: `TwoBoneIK3D` on each leg pins a planted foot in world space until the clip
  lifts it, which kills the remaining skate.
- **Turn steps**: when the facing changes by more than about 20° (sidesteps, crossing over a
  knocked-down opponent), the feet take a small pivot step instead of the whole body rotating.

### Phase 2 · Transitions (1 session)

- Move playback onto an `AnimationTree` (state machine for locomotion, one-shot slot for
  attacks and reactions) while keeping the exact clip-time seek that ties attack art to frame
  data.
- Per-transition blend times and curves instead of one 0.08 s: into an attack 0.03–0.05 s; a
  hit reaction cuts in (the snap is the impact); recovery back to guard eases out over
  0.12–0.2 s; getup to guard 0.2 s.
- Recovery frames blend toward the stance the fighter is about to be in (crouch or stand,
  walking or not) instead of always the standing guard.

### Phase 3 · A procedural layer on top of every clip (1–2 sessions)

All `SkeletonModifier3D` nodes on the fighter's skeleton, render only:

- **Head and upper spine track the opponent** (`LookAtModifier3D`, partial weights: head 60%,
  neck 30%, upper spine 15%), switched off during attacks that turn away on purpose.
- **Weight in the hips**: lean into acceleration, rock back when stopping, dip on landing and
  on taking a hit, driven by the fighter's velocity change.
- **Secondary motion**: spring bones on hair, belts, sashes, headbands and loose sleeves
  (`SpringBoneSimulator3D`), the item the graphics plan named as the change that makes
  fighters feel alive and that was never built.
- **Smoothing guard**: `LimitAngularVelocityModifier3D` on the spine and head so no snap reads
  faster than a human neck.
- **Fatigue**: breathing deeper and the guard dropping a little as health falls.

### Phase 4 · Hit, block and knockdown reactions (2 sessions)

- **Graded, directional hits**: head snapped left, right or back by the attack's side and
  height; body hits fold the torso; lows buckle the knee; heavy and counter hits stagger a step.
  Picked from the hit's level, side and damage, so the same seed always shows the same reaction.
- **Additive hit layer**: a short recoil added on top of whatever the fighter was doing, so a
  hit mid-attack still reads.
- **Crouching hit and block**: real recoil clips instead of the frozen crouch pose.
- **Blockstun**: arms absorb and the body slides back with the push, recovering over the stun
  frames instead of holding frame 0.
- **Falls and getups**: knockdown fall, a lying loop that breathes, two or three getups (roll
  back, kip-up for the agile fighters, push up for the heavies), the tech roll. Optionally a
  ragdoll for the final K.O. fall only (`PhysicalBoneSimulator3D`), where no gameplay follows.

### Phase 5 · The attacks (3–4 sessions)

- **Animation principles in the clip builder** (`build_fight_animations.gd`): per-bone time
  offsets so hips lead, the shoulder follows and the fist or foot whips through last;
  anticipation inside the startup frames; a hard ease into the impact key; overshoot and a
  slower settle in recovery; the support foot pivoting and the free arm counterbalancing.
- **Captured motion where it beats the builder**: kicks, sweeps and the uppercut from source B
  or C, retargeted and trimmed so `animation_impact` still lands on the first active frame.
- The `reach unchanged` check from phase 0 guards every replaced clip.

### Phase 6 · Personality (1 session, then ongoing)

- Per-fighter movement character from the same clips: stance width, bounce height, walk
  tempo, guard height and how fast they settle (Lian light and quick, Brutus planted, Valka
  long and upright). Mostly data on `CharacterData`, read by phases 1 and 3.

## Order and effort

| Phase | Sessions | What it fixes |
|---|---|---|
| 0 Baseline and checks | 1 | Gives every later phase a measure |
| 1 Footwork and stance | 2–3 | Gliding, moonwalking, skating feet, the dead idle |
| 2 Transitions | 1 | Hard cuts, pops back to guard |
| 3 Procedural layer | 1–2 | Lifeless heads, no weight, stiff hair and clothes |
| 4 Reactions | 2 | Frozen blocks, one flinch for everything, stiff falls |
| 5 Attacks | 3–4 | The lockstep, even-speed strikes |
| 6 Personality | 1 | Every fighter moving the same way |

Phases 1 and 3 give the most visible change for the least work and should come first after
the baseline. Phase 5 is the biggest job and depends on the source decision.

## Constraints

- Gameplay never reads a bone: hit boxes, push boxes and frame data stay where they are, and
  the simulation stays deterministic for a seed (all of this runs in `_process`).
- Online play and replays are unaffected for the same reason.
- Low graphics keeps the clips and drops the procedural layer if it costs frames there.
- Every new clip and its source goes in `assets/CREDITS.md`.
