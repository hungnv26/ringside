extends SceneTree
## Measures how the fighters move (docs/movement-plan.md, phase 0). Headless:
##   godot --headless --fixed-fps 60 --path . -s res://tools/check_motion.gd -- [--write-baseline] [--strict] [--only <id>]
## Reel (windowed, one rendered frame per tick, for before/after video):
##   godot --path . --write-movie out.avi --fixed-fps 60 -s res://tools/check_motion.gd -- --reel --only jin [--close]
## --close films from a side camera at chest height 3.6 m away instead of the game camera.
##
## Drives the real fight scene tick by tick with scripted inputs (each fighter in turn as P1
## against Kenji) and renders the model once per tick at 1/60 s, then reports:
## - foot skate: how fast a sole that is on the floor slides along it, per state (cm/s);
## - held poses: ticks where no bone moved more than 2 mm over the last 10 (outside hitstop);
## - reach: every move's striking hand or foot at its impact time, against the baseline in
##   tools/motion_baseline.json, so new art still matches the hit boxes (3 cm allowed).
## --strict exits 1 when skate, held poses or reach miss their targets.
## --blur off|subtle|cinematic|motion|object (reel): motion blur on the filming camera; motion
## and object show the motion vectors / blur vectors as colour (MotionBlur.debug_view).
## --timing (reel, without --fixed-fps): frame pacing (real frame times) and GPU time per frame.
## --strobe (docs/motion-blur-plan.md, phase 0): how far hands, feet and head jump on screen
## between two frames through the game camera, in px on a 1080-line screen, per state.

## Samples a fighter's pose as the skeleton's last modifier, after the motion layer.
class Probe extends SkeletonModifier3D:
	var on_sample: Callable
	func _process_modification_with_delta(_delta: float) -> void:
		on_sample.call()

class Scripted extends FighterController:
	var dir := 5
	var buttons := 0
	func read(_f: Fighter) -> int:
		var p := InputBuffer.pack(dir, buttons)
		buttons = 0
		return p

const DT := 1.0 / 60.0
const BASELINE := "res://tools/motion_baseline.json"
const CONTACT_HEIGHT := 0.03 # a sole this close to the floor is on it
const HELD_WINDOW := 10
const HELD_MOVE := 0.002
const REACH_TOLERANCE := 0.03
## Targets for --strict.
const SKATE_TARGET := 5.0 # cm/s, 90th percentile while a sole is down
const HELD_TARGET := 0 # held ticks allowed per state (KO and victory are exempt)
const POSE_BONES := [&"pelvis", &"spine_02", &"Head", &"upperarm_l", &"lowerarm_l", &"hand_l",
	&"upperarm_r", &"lowerarm_r", &"hand_r", &"thigh_l", &"calf_l", &"foot_l", &"thigh_r", &"calf_r", &"foot_r"]
const SOLE_BONES := [&"foot_l", &"ball_l", &"foot_r", &"ball_r"]
const EFFECTORS := [&"hand_l", &"hand_r", &"ball_leaf_l", &"ball_leaf_r"]
const HELD_EXEMPT := ["KO"]
## The whole body slides in these (knocked flying, lying, thrown): no feet to plant.
const SKATE_EXEMPT := ["AIR_HIT", "KNOCKDOWN", "KO", "THROWN", "WALL_SPLAT"]

var m
var p1: Fighter
var p2: Fighter
var ctl := Scripted.new()
var ctl2 := Scripted.new()
## state name -> {skate: PackedFloat32Array (cm/s samples), held: int, ticks: int}
var stats := {}
var _prev_soles := {} # fighter -> {bone: Vector3 or null}
var _pose_history := {} # fighter -> Array of PackedVector3Array
var reel := false
var pops := PackedFloat32Array() # cm/tick a bone's speed changed in the tick its clip changed
var steady := PackedFloat32Array() # and in ticks without a change, for scale
var _last_clip := {}
var _last_state := {}
var _last_pos := {}
var _states_seen := {}
var pops_by := {} # "FROM>TO" -> PackedFloat32Array
var debug_feet := false
var feet_frame := false # --feet: P1's feet in its own frame while standing and moving
var trace_from := -1
var trace_change := ""
var _ring := []
var _trace_left := 0
var _tick := 0
var close_camera: Camera3D
var wide_camera := false # --wide: both fighters centred (the framing of the first reels)
var legs_camera := false # --legs: low and close on P1's legs
var strobe := false
var timing := false
var _frame_usec := PackedInt64Array()
var _gpu_ms := PackedFloat32Array()
var _last_usec := 0
var strobe_by := {} # state name -> PackedFloat32Array of px gaps
var _last_screen := {} # fighter -> PackedVector2Array
var _last_camera := Transform3D()
const STROBE_BONES := [&"hand_l", &"hand_r", &"ball_leaf_l", &"ball_leaf_r", &"Head"]


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var write_baseline := args.has("--write-baseline")
	var strict := args.has("--strict")
	reel = args.has("--reel")
	FighterModel.eased_transitions = not args.has("--linear-fades")
	debug_feet = args.has("--debug-feet")
	feet_frame = args.has("--feet")
	if args.has("--trace-change"):
		trace_change = args[args.find("--trace-change") + 1]
	if args.has("--trace"):
		trace_from = int(args[args.find("--trace") + 1])
	var close := args.has("--close") or args.has("--wide") or args.has("--legs")
	legs_camera = args.has("--legs")
	wide_camera = args.has("--wide")
	strobe = args.has("--strobe")
	timing = args.has("--timing")
	if timing:
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
		if args.has("--no-vsync"): # frame times then show the cost (Metal reports no GPU time)
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0
	var only := ""
	if args.has("--only"):
		only = args[args.find("--only") + 1]
	var gs = root.get_node("GameState")
	var roster: Array = gs.roster
	var ok := true

	for character: CharacterData in roster:
		if only != "" and character.id != only:
			continue
		gs.player_character = character
		gs.p2_character = roster[0] # Kenji
		change_scene_to_file("res://scenes/fight.tscn")
		await process_frame
		await process_frame
		m = current_scene
		m.set_physics_process(false)
		p1 = m.fighters[0]
		p2 = m.fighters[1]
		if not reel:
			for f: Fighter in [p1, p2]:
				var probe := Probe.new()
				probe.on_sample = _sample.bind(f)
				f.model.skeleton.add_child(probe)
		elif close:
			close_camera = Camera3D.new()
			close_camera.fov = 40.0
			m.add_child(close_camera)
			close_camera.make_current()
		if reel and args.has("--blur"):
			var how: String = args[args.find("--blur") + 1]
			var camera: Camera3D = close_camera if close_camera else m.camera
			var level := MotionBlur.Level.CINEMATIC if how in ["cinematic", "motion", "object", "camera", "depth"] else (MotionBlur.Level.SUBTLE if how == "subtle" else MotionBlur.Level.OFF)
			var effect := MotionBlur.attach(camera, level)
			if effect:
				effect.debug_view = {"motion": 1, "object": 2, "camera": 3, "depth": 4}.get(how, 0)
		await _run_scenarios()
		if reel:
			if timing:
				_timing_report()
			quit()
			return

	var report := _report()
	print(report.text)
	if strobe:
		print(_strobe_report())
	if FighterMotion.cost_calls > 0:
		print("motion layer: %.0f µs per fighter per frame (%d frames)" % [float(FighterMotion.cost_usec) / FighterMotion.cost_calls, FighterMotion.cost_calls])
	ok = report.ok

	var reach := _measure_reach(roster, only)
	if write_baseline:
		var f := FileAccess.open(BASELINE, FileAccess.WRITE)
		f.store_string(JSON.stringify(reach, "\t", true))
		print("baseline written: %d moves" % reach.size())
	elif FileAccess.file_exists(BASELINE):
		var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
		var worst := 0.0
		var off := []
		for key: String in base:
			if not reach.has(key):
				continue
			var b: Array = base[key]
			var bone: String = b[0]
			var now: Array = reach[key]
			var at := Vector3(b[1], b[2], b[3])
			var p: Dictionary = now[4]
			var current := Vector3(p[bone][0], p[bone][1], p[bone][2])
			var d := at.distance_to(current)
			worst = maxf(worst, d)
			if d > REACH_TOLERANCE:
				off.append("%s %s %.1f cm" % [key, bone, d * 100.0])
		print("reach: %d moves checked, worst %.1f cm, %d over %.0f cm%s" % [base.size(), worst * 100.0, off.size(), REACH_TOLERANCE * 100.0, (": " + ", ".join(off.slice(0, 12))) if off else ""])
		if off:
			ok = false
	print("RESULT ", "ok" if ok else "targets missed")
	quit(1 if strict and not ok else 0)


# --- scenarios ------------------------------------------------------------------------

func step(n := 1) -> void:
	for i in n:
		m._physics_process(DT)
		if close_camera:
			_aim_close_camera()
		await process_frame # one frame per tick (--fixed-fps 60): _process, the motion layer, the probe
		if timing:
			var now := Time.get_ticks_usec()
			if _last_usec > 0:
				_frame_usec.append(now - _last_usec)
			_last_usec = now
			_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))


## Side on to the line between the fighters, on the game camera's side of it.
func _aim_close_camera() -> void:
	var mid := p1.global_position.lerp(p2.global_position, 0.5 if wide_camera else 0.12)
	var across := (p2.global_position - p1.global_position)
	across.y = 0.0
	var side := Vector3.UP.cross(across.normalized()) if across.length() > 0.01 else Vector3.BACK
	var game_camera: Camera3D = m.camera
	if side.dot(game_camera.global_position - mid) < 0.0:
		side = -side
	if legs_camera:
		var low := p1.global_position + Vector3.UP * 0.55
		close_camera.global_position = low + side * 2.0 + Vector3.UP * 0.05
		close_camera.look_at(low)
		return
	var target := mid + Vector3.UP * 1.0
	close_camera.global_position = target + side * (3.6 if wide_camera else 3.3) + Vector3.UP * (0.15 if wide_camera else 0.1)
	close_camera.look_at(target)


func hold(d: int, n: int) -> void:
	ctl.dir = d
	await step(n)


func tap(dirs: Array) -> void:
	for d: int in dirs:
		ctl.dir = d
		await step(1)


func press(who: Scripted, button: int, d := 5) -> void:
	who.dir = d
	who.buttons = button
	await step(1)


func fresh() -> void:
	m.start_match()
	m.start_fight_immediately()
	p1.controller = ctl
	p2.controller = ctl2
	ctl.dir = 5
	ctl2.dir = 5
	_prev_soles.clear()
	_pose_history.clear()
	await step(2)
	# The reset lands on the first tick: start the histories after it.
	_prev_soles.clear()
	_pose_history.clear()
	_last_clip.clear()


func dist() -> float:
	return Vector2(p2.position.x - p1.position.x, p2.position.z - p1.position.z).length()


func close_in(target: float) -> void:
	ctl.dir = 6
	var guard := 0
	while dist() > target and guard < 400:
		await step()
		guard += 1
	ctl.dir = 5
	await step(20)


func _run_scenarios() -> void:
	await fresh()
	await hold(5, 120) # idle
	await hold(6, 50) # walk forward
	await hold(5, 20)
	await hold(4, 70) # walk back
	await hold(5, 20)
	await hold(2, 50) # crouch
	await hold(5, 20)
	await tap([6, 5, 6]) # dash
	await hold(5, 40)
	await tap([4, 5, 4]) # backdash
	await hold(5, 40)
	await press(ctl, InputBuffer.SIDESTEP, 8) # sidestep away from the camera
	await hold(5, 30)
	await press(ctl, InputBuffer.SIDESTEP, 2) # and toward it
	await hold(5, 30)
	await hold(8, 4) # jump
	await hold(5, 70)

	# Get hit standing (high, mid), crouching; block standing and crouching; get swept.
	await fresh()
	for hit: Array in [[5, InputBuffer.HP, 5], [5, InputBuffer.LK, 5], [2, InputBuffer.HP, 5],
			[4, InputBuffer.HP, 5], [1, InputBuffer.LK, 2], [5, InputBuffer.HK, 2]]:
		await close_in(1.0)
		ctl.dir = hit[0]
		await press(ctl2, hit[1], hit[2])
		await step(50 if hit[1] != InputBuffer.HK else 130)
		ctl.dir = 5
	# Attack: the normals once each.
	await fresh()
	await close_in(1.1)
	for b in [InputBuffer.LP, InputBuffer.HP, InputBuffer.LK, InputBuffer.HK]:
		await press(ctl, b)
		await step(45)
	for b in [InputBuffer.LP, InputBuffer.HK]:
		await press(ctl, b, 2)
		await step(45)


# --- sampling -----------------------------------------------------------------------

func _sample(f: Fighter) -> void:
	if f.model == null:
		return
	if trace_change != "" and (f == p1 or f == p2):
		var sk1 := f.model.skeleton
		var desc := "%s clip=%s pelvis %s Head %s hand_l %s body_y %.3f" % [Fighter.State.keys()[f.state], f.model._clip,
			(sk1.get_bone_global_pose(sk1.find_bone(&"pelvis")).origin * 100.0).snapped(Vector3.ONE * 0.1),
			(sk1.get_bone_global_pose(sk1.find_bone(&"Head")).origin * 100.0).snapped(Vector3.ONE * 0.1),
			(sk1.get_bone_global_pose(sk1.find_bone(&"hand_l")).origin * 100.0).snapped(Vector3.ONE * 0.1), f.model.skeleton.global_position.y]
		_ring.append(desc)
		if _ring.size() > 4:
			_ring.pop_front()
		var key := "%s>%s" % [Fighter.State.keys()[_last_state.get(f, 0)], Fighter.State.keys()[f.state]]
		if key == trace_change and _trace_left == 0:
			print("---- ", key)
			for r in _ring:
				print("  ", r)
			_trace_left = 6
		elif _trace_left > 0:
			print("  ", desc)
			_trace_left -= 1
	if trace_from >= 0 and f == p1 and _tick >= trace_from and _tick < trace_from + 14:
		var sk0 := f.model.skeleton
		var parts := []
		for bn in [&"pelvis", &"Head", &"hand_l", &"calf_l", &"foot_l"]:
			parts.append("%s %s" % [bn, (sk0.get_bone_global_pose(sk0.find_bone(bn)).origin * 100.0).snapped(Vector3.ONE * 0.1)])
		print("T%d %s clip=%s  %s" % [_tick, Fighter.State.keys()[f.state], f.model._clip, "  ".join(parts)])
	if f == p1:
		_tick += 1
	if feet_frame and f == p1 and f.state in [Fighter.State.IDLE, Fighter.State.WALK_FWD, Fighter.State.WALK_BACK, Fighter.State.DASH, Fighter.State.BACKDASH, Fighter.State.SIDESTEP]:
		var sk2 := f.model.skeleton
		var xf2 := sk2.global_transform
		var fwd := f.forward
		var right := fwd.cross(Vector3.UP).normalized()
		var line := "%s f%d" % [Fighter.State.keys()[f.state], f.state_frame]
		for side in ["l", "r"]:
			var ankle := xf2 * sk2.get_bone_global_pose(sk2.find_bone("foot_" + side)).origin
			var toe := xf2 * sk2.get_bone_global_pose(sk2.find_bone("ball_" + side)).origin
			var knee := xf2 * sk2.get_bone_global_pose(sk2.find_bone("calf_" + side)).origin
			var hip := xf2 * sk2.get_bone_global_pose(sk2.find_bone("thigh_" + side)).origin
			var rel := ankle - f.global_position
			var toe_dir := (toe - ankle)
			var yaw := rad_to_deg(Vector2(toe_dir.dot(fwd), toe_dir.dot(right)).angle())
			# knee direction relative to the hip-ankle line, sideways component (+ = toward the fighter's right)
			var mid := hip.lerp(ankle, 0.5)
			var knee_side := (knee - mid).dot(right)
			var knee_fwd := (knee - mid).dot(fwd)
			var hip_rel := hip - f.global_position
			line += "  %s hip fwd %+.2f side %+.2f | ankle fwd %+.2f side %+.2f toe %+4.0f° knee fwd %+.2f side %+.2f" % [side, hip_rel.dot(fwd), hip_rel.dot(right), rel.dot(fwd), rel.dot(right), yaw, knee_fwd, knee_side]
		print("FEET ", line)
	if debug_feet and f == p1 and f.state in [Fighter.State.DASH, Fighter.State.BACKDASH, Fighter.State.SIDESTEP, Fighter.State.LANDING, Fighter.State.JUMP_SQUAT, Fighter.State.JUMP]:
		var mo := f.model.motion
		var line := "%s f%d v=%.2f" % [Fighter.State.keys()[f.state], f.state_frame, mo._velocity.length()]
		for side in ["l", "r"]:
			var ft: Dictionary = mo._feet[side]
			line += "  %s:%s%s u=%.2f lift=%s y=%.3f" % [side, "P" if ft.planted else "-", "S" if ft.swinging else "-", ft.u, ft.lifted, (mo.solved_feet.get(side, Vector3.ZERO) as Vector3).y]
		print(line)
	var state_name: String = Fighter.State.keys()[f.state]
	if not stats.has(state_name):
		stats[state_name] = {skate = PackedFloat32Array(), held = 0, ticks = 0}
	var s: Dictionary = stats[state_name]
	s.ticks += 1
	var sk := f.model.skeleton
	var xf := sk.global_transform
	var scale := f.model.scale.y
	# Foot skate: a sole that was on the floor last tick and still is.
	var prev: Dictionary = _prev_soles.get(f, {})
	var now := {}
	for bone_name: StringName in SOLE_BONES:
		var bone := sk.find_bone(bone_name)
		var p := xf * sk.get_bone_global_pose(bone).origin
		var rest_y := sk.get_bone_global_rest(bone).origin.y * scale
		var side_name := String(bone_name).right(1)
		var swept: bool = f.model.motion.attacking and not f.model.motion._feet[side_name].planted
		if p.y - rest_y < CONTACT_HEIGHT and not swept:
			now[bone_name] = p
			if prev.has(bone_name) and f.hitstop == 0 and not f.frozen:
				var q: Vector3 = prev[bone_name]
				s.skate.append(Vector2(p.x - q.x, p.z - q.z).length() / DT * 100.0)
				if debug_feet and f == p1 and state_name == "LANDING":
					print("  skate LANDING f%d %s %.1f cm/s" % [f.state_frame, bone_name, Vector2(p.x - q.x, p.z - q.z).length() / DT * 100.0])
	_prev_soles[f] = now
	# A reset (new round) teleports the fighter: start its history again.
	var at := f.global_position
	if _last_pos.has(f) and (_last_pos[f] as Vector3).distance_to(at) > 0.5:
		_pose_history.erase(f)
		_last_clip.erase(f)
	_last_pos[f] = at
	if strobe:
		_sample_strobe(f, state_name)
	var ring: Array = _states_seen.get(f, [])
	ring.append("%s/%s/f%d/h%d" % [Fighter.State.keys()[f.state], String(f.model._clip).get_file(), f.state_frame, f.hitstop])
	if ring.size() > 6:
		ring.pop_front()
	_states_seen[f] = ring
	# Held pose: nothing moved more than HELD_MOVE over the last HELD_WINDOW ticks.
	var pose := PackedVector3Array()
	for bone_name: StringName in POSE_BONES:
		pose.append(sk.get_bone_global_pose(sk.find_bone(bone_name)).origin)
	var history: Array = _pose_history.get(f, [])
	history.append(pose)
	if history.size() > HELD_WINDOW:
		history.pop_front()
	_pose_history[f] = history
	if history.size() >= 3 and f.hitstop == 0 and not f.frozen:
		# How suddenly a bone changed speed: |this tick's move - last tick's move|.
		var jump := 0.0
		for i in pose.size():
			var d2: Vector3 = pose[i] - history[-2][i]
			var d1: Vector3 = history[-2][i] - history[-3][i]
			jump = maxf(jump, (d2 - d1).length())
		var changed: bool = _last_clip.get(f, &"") != f.model._clip
		(pops if changed else steady).append(jump * 100.0)
		if changed:
			var key := "%s>%s" % [Fighter.State.keys()[_last_state.get(f, 0)], Fighter.State.keys()[f.state]]
			if jump > 0.2 and debug_feet:
				var worst := 0
				for i in pose.size():
					var dd: Vector3 = (pose[i] - history[-2][i]) - (history[-2][i] - history[-3][i])
					var dw: Vector3 = (pose[worst] - history[-2][worst]) - (history[-2][worst] - history[-3][worst])
					if dd.length() > dw.length():
						worst = i
				print("  states: ", _states_seen.get(f, []))
				print("POP %s %s %.1f cm/tick at %s, positions %s -> %s -> %s | phase %s frame %d hitstop %d pos %s mode %s planted %s" % [f.data.id, key, jump * 100.0, POSE_BONES[worst], history[-3][worst], history[-2][worst], pose[worst], m.phase, f.state_frame, f.hitstop, f.global_position, f.model.motion.mode, f.model.motion._feet["r"]])
			if not pops_by.has(key):
				pops_by[key] = PackedFloat32Array()
			pops_by[key].append(jump * 100.0)
	_last_clip[f] = f.model._clip
	_last_state[f] = f.state
	if history.size() == HELD_WINDOW and f.hitstop == 0 and not f.frozen:
		var moved := 0.0
		for i in pose.size():
			moved = maxf(moved, (history[0][i] as Vector3).distance_to(pose[i]))
		if moved < HELD_MOVE:
			s.held += 1


func _report() -> Dictionary:
	var lines := ["", "| state | ticks | skate p50 cm/s | skate p90 cm/s | held ticks |", "|---|---|---|---|---|"]
	var ok := true
	var names := stats.keys()
	names.sort()
	for state_name: String in names:
		var s: Dictionary = stats[state_name]
		var skate: PackedFloat32Array = s.skate
		var sorted := Array(skate)
		sorted.sort()
		var p50: float = sorted[int(sorted.size() * 0.5)] if sorted else 0.0
		var p90: float = sorted[int(sorted.size() * 0.9)] if sorted else 0.0
		var flags := ""
		if p90 > SKATE_TARGET and not SKATE_EXEMPT.has(state_name):
			flags += " SKATE"
			ok = false
		if s.held > HELD_TARGET and not HELD_EXEMPT.has(state_name):
			flags += " HELD"
			ok = false
		lines.append("| %s | %d | %.1f | %.1f | %d |%s" % [state_name, s.ticks, p50, p90, s.held, flags])
	var pc := Array(pops)
	pc.sort()
	var st := Array(steady)
	st.sort()
	if pc:
		lines.append("")
		lines.append("clip changes: %d, sharpest change of bone speed that tick p50 %.1f cm/tick, p90 %.1f, max %.1f (other ticks p90 %.1f)" % [pc.size(),
			pc[int(pc.size() * 0.5)], pc[int(pc.size() * 0.9)], pc[-1], st[int(st.size() * 0.9)] if st else 0.0])
	var keys := pops_by.keys()
	keys.sort_custom(func(a, b): return (pops_by[a] as PackedFloat32Array).size() > (pops_by[b] as PackedFloat32Array).size())
	for key: String in keys.slice(0, 10):
		var v := Array(pops_by[key])
		v.sort()
		lines.append("  %s: %d, p50 %.1f, max %.1f" % [key, v.size(), v[int(v.size() * 0.5)], v[-1]])
	return {text = "\n".join(lines), ok = ok}


# --- reach --------------------------------------------------------------------------

## Every move's effectors at its impact time, in the model's own space (+Z toward the
## opponent). The striking one is the effector furthest forward at baseline time.
func _measure_reach(roster: Array, only: String) -> Dictionary:
	var out := {}
	for character: CharacterData in roster:
		if only != "" and character.id != only:
			continue
		var model := FighterModel.new()
		root.add_child(model)
		model.build(character)
		var sk := model.skeleton
		for move: MoveData in character.moves:
			if move.animation == &"" or not model.player.has_animation(move.animation):
				continue
			model.player.play(move.animation, 0.0)
			model.player.seek(move.animation_impact, true)
			model.player.advance(0.0)
			var points := {}
			var best := ""
			var best_z := -INF
			for bone_name: StringName in EFFECTORS:
				var p := sk.get_bone_global_pose(sk.find_bone(bone_name)).origin
				points[String(bone_name)] = [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001)]
				if p.z > best_z:
					best_z = p.z
					best = String(bone_name)
			var bp: Array = points[best]
			out["%s/%s" % [character.id, move.name]] = [best, bp[0], bp[1], bp[2], points]
		model.free()
	return out


# --- strobe -------------------------------------------------------------------------

## Screen gap of the fastest effector since the last frame, at 1080 lines. A camera cut or a
## teleport (round reset) starts again.
func _sample_strobe(f: Fighter, state_name: String) -> void:
	var camera: Camera3D = m.camera
	var cut := camera.global_transform.origin.distance_to(_last_camera.origin) > 0.4
	if f == p2:
		_last_camera = camera.global_transform
	var sk := f.model.skeleton
	var xf := sk.global_transform
	var lines := 1080.0 / camera.get_viewport().get_visible_rect().size.y
	var now := PackedVector2Array()
	for bone_name: StringName in STROBE_BONES:
		var world := xf * sk.get_bone_global_pose(sk.find_bone(bone_name)).origin
		now.append(camera.unproject_position(world) * lines)
	var prev: PackedVector2Array = _last_screen.get(f, PackedVector2Array())
	_last_screen[f] = now
	if prev.is_empty() or cut or f.hitstop > 0 or f.frozen or not _pose_history.has(f):
		return
	var gap := 0.0
	for i in now.size():
		gap = maxf(gap, now[i].distance_to(prev[i]))
	if not strobe_by.has(state_name):
		strobe_by[state_name] = PackedFloat32Array()
	strobe_by[state_name].append(gap)


func _strobe_report() -> String:
	var lines := ["", "strobe: the fastest hand, foot or head's jump between frames (px at 1080 lines)", "| state | frames | p50 | p95 | max |", "|---|---|---|---|---|"]
	var all := []
	var names := strobe_by.keys()
	names.sort()
	for state_name: String in names:
		var v := Array(strobe_by[state_name])
		v.sort()
		all.append_array(v)
		lines.append("| %s | %d | %.0f | %.0f | %.0f |" % [state_name, v.size(), v[int(v.size() * 0.5)], v[int(v.size() * 0.95)], v[-1]])
	all.sort()
	if all:
		lines.append("| all | %d | %.0f | %.0f | %.0f |" % [all.size(), all[int(all.size() * 0.5)], all[int(all.size() * 0.95)], all[-1]])
	return "\n".join(lines)


## Frame pacing and GPU time over the reel (the first second is skipped: loading).
func _timing_report() -> void:
	var frames := Array(_frame_usec.slice(60))
	var gpu := Array(_gpu_ms.slice(60))
	if frames.is_empty():
		return
	frames.sort()
	gpu.sort()
	var median: float = frames[frames.size() / 2]
	var late := frames.filter(func(u): return u > median * 1.5).size()
	print("pacing: %d frames, median %.2f ms, p99 %.2f ms, max %.2f ms, %d over 1.5x the median" % [frames.size(), median / 1000.0, frames[int(frames.size() * 0.99)] / 1000.0, frames[-1] / 1000.0, late])
	print("gpu: median %.2f ms, p95 %.2f ms per frame" % [gpu[gpu.size() / 2], gpu[int(gpu.size() * 0.95)]])
