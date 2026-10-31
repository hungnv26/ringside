# Cinematic motion: motion blur for the fighters

Asked 2026-10-31: "movement of character is not very smooth. It is not about the frame rate,
i think it about connecting the frame to make it motion blur, more cinematic, more like human
can see."

## What is wrong

The movement itself is continuous: fighters' positions are interpolated between the 60 Hz
simulation ticks (`physics_interpolation`), and poses are sampled at the render rate
(`Fighter._process` → `FighterModel.show_clip`). What the eye objects to is that every frame
is a perfectly sharp instant. A camera with a shutter, or an eye watching a real kick, sees
the limb smeared along the path it travelled while the shutter was open. The game shows
the foot sharp in one place, then sharp half a metre further on: a strobe.

Measured on Kenji's clips (hands and feet, sampled at 240 Hz), at the default 1080p window
with the fight camera (45° field of view, about 4.5 m away: about 290 px per metre):

| Motion | Limb speed | Gap between two 60 Hz frames |
|---|---|---|
| Fast strikes (high kick, roundhouse, rushing hook, flip kick) | 30 to 70 m/s | 0.5 to 1.2 m: 145 to 340 px |
| Typical limb motion (median clip) | 8 m/s | 13 cm: 39 px |

(The clips are stylised: a real elite kick peaks near 15 to 25 m/s.) Godot 4.7.2 has no
built-in motion blur, but it can write a per-pixel motion-vector buffer (used by TAA), and
a `CompositorEffect` can read it. That is the basis of the live path below.

## Goal

- Fast limbs streak along their path; slow and still things stay sharp (the face, the torso
  in guard, the stage).
- The look of a 180° film shutter: each frame blurs over half of a 60 Hz frame (1/120 s),
  the same exposure whatever the refresh rate, so 120 Hz looks the same as 60 Hz, just finer.
- Hitstop freezes stay crisp (they are what sells an impact). Camera cuts never smear.
- Purely cosmetic: no change to gameplay, reach, or the simulation; checks stay green.

## Phases

### Phase 0: measure and set the target (half a day)

1. **Strobe meter** in `tools/check_motion.gd` (`--strobe`): projects hands, feet and head to
   the screen every frame and reports the gap between frames in pixels (p50, p95, max per
   move), so every later phase is measured against these numbers.
2. **Reference render**: record a short reel at 480 fps (`--write-movie --fixed-fps 480`) and
   average 4 of every 8 frames into one 60 fps frame (a true 180° shutter). This is the
   ground truth for how the blur should look, with no shader artefacts.
3. **Motion-vector check**: confirm Godot writes correct motion vectors for *skinned* meshes
   (a kicking leg, not just the moving body) by viewing the velocity buffer in a debug
   effect. This decides Phase 1's approach (see Risks).
4. **Frame-pacing check**: log frame times during a live match. Uneven frames (judder) feel
   "not smooth" too, and blur would hide it badly. If pacing is uneven, fix that first.

### Phase 1: per-object motion blur, live (one and a half to two days)

A `CompositorEffect` (`scripts/fx/motion_blur.gd` plus a compute shader) after the opaque
pass, with `needs_motion_vectors = true`:

1. **Tiles**: the largest motion in each 20 × 20 px tile, then the largest among neighbours,
   so a fast foot blurs past its own silhouette (the McGuire reconstruction filter, the
   standard way games do this).
2. **Gather**: 8 to 12 samples along each pixel's motion, weighted by depth so a moving
   limb smears over the background but the background never smears onto the fighter.
3. **Shutter**: blur length = velocity × exposure (1/120 s by default), capped at about
   48 px at 1080p (scaled with resolution) so the fastest strikes don't turn into ghosts.
4. **Camera**: camera motion is mostly subtracted (a whip pan stays readable); the frame of a
   camera cut, a round reset or a replay jump skips the blur (the camera already reports
   cuts). Hitstop has zero motion, so freezes stay crisp by themselves.
5. **Settings**: a *Motion blur* option (Off / Subtle / Cinematic) in Options and on the
   setup page; on by default at High and Showcase, off at Low. Target cost: under 1 ms
   per frame at 1080p on this Mac.

### Phase 2: smear on the fastest strikes (half a day)

The capped blur stops short on the very fastest strikes (over about 30 m/s). For those,
during a move's active frames only, the existing limb trails (`LimbTrail` in
`scripts/fx/fight_fx.gd`) become short, soft, velocity-driven smears that follow the striking
limb's last few positions and fade within 2 to 3 frames: the "smear frame" that animated
fighting games use. Tuned so it reads as speed, not as a special effect.

### Phase 3: true motion blur in recordings (half a day to a day)

Recordings are rendered offline, so they can afford the real thing. With *Record the match*,
the game renders at 240 fps (`--fixed-fps 240`; the 60 Hz simulation and interpolation are
unchanged) and ffmpeg averages each pair of consecutive frames out of every four into one
60 fps frame (`tmix` plus `select`): an exact 180° shutter, including skinned limbs, with no
shader artefacts. The live shader is off while doing this. It costs about 4× the render
time (a 3-minute match records in about 40 minutes instead of 10), so it gets its own
checkbox ("Film-quality motion blur") instead of being forced on. Also check that the
coaches' turn cadence follows game time, not wall time, when the game runs slower than
real time.

### Phase 4: tune and prove (half a day)

- Before/after videos: the same exchange (a fast kick string, a sidestep, a knockdown) with
  blur off, the live shader and the film path, side by side.
- Tune exposure, cap and sample count per graphics preset against the Phase 0 reference.
- Checks: the strobe meter's p95 gap at 180° shutter halves by construction; idle and
  held-pose pixels move under 0.5 px; no smear on cut frames; cost under 1 ms; reach and
  footwork numbers from `check_motion.gd` unchanged; sim and coach tests pass.

## Risks

- **Skinned motion vectors.** If Godot's velocity buffer only carries object and camera
  motion, not bone motion, the shader would blur a walking body but not a kicking leg.
  Fallback: render the fighters' own per-vertex velocity (current minus previous skinned
  position, from the skeleton's previous pose) into a separate buffer, or rely more on
  Phase 2 smears live and Phase 3 for recordings. Phase 0 settles this before any shader
  work.
- **MSAA.** Motion vectors with 2×/4× MSAA may need resolving; if they conflict, the effect
  reads the resolved velocity, or High switches to a temporal or FXAA path.
- **Too much blur feels like lag** in a fighting game. Players need to read startup frames.
  Hence the cap, the Subtle default for local play, and Cinematic for watching coached
  matches and recordings.

## Order and size

| Phase | What | Size |
|---|---|---|
| 0 | Strobe meter, reference render, motion-vector and pacing checks | ½ day |
| 1 | Live per-object motion blur (compositor effect) and setting | 1½ to 2 days |
| 2 | Velocity-driven smears on the fastest strikes | ½ day |
| 3 | Film-quality blur in recordings (240 fps, frame blending) | ½ to 1 day |
| 4 | Tuning, before/after videos, checks | ½ day |

## Progress (built 2026-11-01)

All five phases are built. What changed against the plan is noted per phase.

**Phase 0.** `tools/check_motion.gd --strobe` measures how far a hand, foot or head jumps on
screen between frames through the game camera (px at 1080 lines; one P1 per fighter against
Kenji, 21,436 frames):

| State | p50 | p95 | Max |
|---|---|---|---|
| Attack | 12 | 100 | 255 |
| Getup | 35 | 150 | 167 |
| Knocked into the air | 64 | 93 | 108 |
| Walk forward | 13 | 30 | 85 |
| Idle | 1 | 9 | 68 |

The motion-vector check settled the main risk: Godot 4.7.2 writes motion vectors for skinned
meshes (a kicking leg has its own, not just the body's), with MSAA on, so no per-vertex
fallback was needed. `get_cam_projection()` is already in the renderer's own convention
(debug views 3 and 4: the reprojected camera motion matches the motion vectors of the
stage). Frame pacing (`--timing`, a live run at 120 Hz) is clean: 6 or 7 frames in 1,515 over
1.5× the median, all at loading. The 480 fps reference render was not used: the motion
reel steps one simulation tick per rendered frame, so it can't render sub-frames; the film
path of Phase 3 (a real match) became the reference instead.

**Phase 1.** `scripts/fx/motion_blur.gd` and `motion_blur.glsl`: a `CompositorEffect` after
the transparent pass, in four compute passes (each pixel's blur vector and distance once,
16-px tiles, 3×3 neighbourhood, a depth-weighted gather of 13 samples). Exposure is shutter ÷
real frame time, so 120 Hz looks like 60 Hz and slow motion (filmed "at a high frame rate")
blurs less; the camera's own motion counts 35%; a camera jump of 0.6 m or 25° in a frame is a
cut and stays sharp; hitstop has no motion, so impact freezes stay crisp. Levels: Off,
Subtle (1/240 s, at most 32 px), Cinematic (1/120 s, at most 56 px). The Options menu has
*Motion Blur* (default Subtle; none at Low); coached matches take `--motion-blur` (default
Cinematic, also on the setup page). Cost with the 3D drawn at 1920×1080 (High, the
default 1080-line cap) on this Mac (frame time with vsync off, the motion reel): 6.84 ms off, 7.73 ms Cinematic, **about 0.9 ms**. A first version that
reprojected every sample cost 1.05 ms.

**Phase 2.** With motion blur on, `LimbTrail` is a smear instead of a ribbon: a strip over
one frame's travel of the striking limb, only when the limb moves further than the blur's
longest streak covers, as strong as the gap is uncovered, gone within 3 frames (real time,
through hitstop). In the motion reel only Kenji's fastest mid kick (gaps up to 141 px) earns
one, at a quarter strength: everything slower is covered by the blur alone. With the blur
off the old ribbons are unchanged.

**Phase 3.** `--film` (setup page: *Film-quality motion blur*, with *Record*): the game renders
240 frames a second at High (each frame blurred over its own 1/240 s, `--motion-blur=film`)
and ffmpeg blends the first two of every four into one 60 fps frame. Godot looks for a movie
writer before any game script runs, so a custom streaming writer couldn't be registered;
Godot's own Theora writer (`.ogv`, with the sound) keeps the temporary movie to about
75 KB a frame at 720p. While recording, the coaches pace their turns by game ticks
(`gameClock` in adapter/src/main.ts), not wall time, so a recording plays like a live match.

Tested end to end (Jin vs Brutus, scripted coaches, 720p): 23,953 frames rendered at 240 fps
in 15 min 29 s (10% of real time) gave a 1 min 40 s video at 60 fps with sound; the coaches
took about 42 turns each, one every 2.4 s of fight time (the 2 s cadence plus their reply),
as live. Unlike the live effect, a blended recording blurs the camera's own motion fully:
a whip pan or the super camera smears the whole background, as a film camera would.

Found on the way: every recording is 1280×720 whatever window is chosen. Godot takes the
movie's size from the project's window setting (`window_width_override`), not from
`--resolution` (tested), and scales the rendered window down to it. Changing that setting
would also change the default window for players, so it is left as it was.

**Phase 4.** Before/after stills in `docs/look/movement/blur_before_after.jpg` (left off,
right Cinematic: a kip-up's legs and a straight punch). Checks: `check_motion.gd` gives the same
numbers as before this work (reach 0.0 cm off in 122 moves; the getup, jump-squat and landing
skate it already flagged are unchanged), sim_test (612) and coach_test pass, and the adapter's
77 tests pass.
