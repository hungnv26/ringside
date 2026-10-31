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
var pops_by := {} # "FROM>TO" -> PackedFloat32Array
var debug_feet := false
var trace_from := -1
var trace_change := ""
var _ring := []
var _trace_left := 0
var _tick := 0
var close_camera: Camera3D


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var write_baseline := args.has("--write-baseline")
	var strict := args.has("--strict")
	reel = args.has("--reel")
	FighterModel.eased_transitions = not args.has("--linear-fades")
	debug_feet = args.has("--debug-feet")
	if args.has("--trace-change"):
		trace_change = args[args.find("--trace-change") + 1]
	if args.has("--trace"):
		trace_from = int(args[args.find("--trace") + 1])
	var close := args.has("--close")
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
		await _run_scenarios()
		if reel:
			quit()
			return

	var report := _report()
	print(report.text)
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


## Side on to the line between the fighters, on the game camera's side of it.
func _aim_close_camera() -> void:
	var mid := p1.global_position.lerp(p2.global_position, 0.12)
	var across := (p2.global_position - p1.global_position)
	across.y = 0.0
	var side := Vector3.UP.cross(across.normalized()) if across.length() > 0.01 else Vector3.BACK
	var game_camera: Camera3D = m.camera
	if side.dot(game_camera.global_position - mid) < 0.0:
		side = -side
	var target := mid + Vector3.UP * 1.0
	close_camera.global_position = target + side * 3.3 + Vector3.UP * 0.1
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
	if debug_feet and f == p1 and f.state in [Fighter.State.DASH, Fighter.State.BACKDASH, Fighter.State.SIDESTEP]:
		var mo := f.model.motion
		var line := "%s f%d v=%.2f" % [Fighter.State.keys()[f.state], f.state_frame, mo._velocity.length()]
		for side in ["l", "r"]:
			var ft: Dictionary = mo._feet[side]
			line += "  %s:%s%s u=%.2f lift=%s" % [side, "P" if ft.planted else "-", "S" if ft.swinging else "-", ft.u, ft.lifted]
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
		if p.y - rest_y < CONTACT_HEIGHT:
			now[bone_name] = p
			if prev.has(bone_name) and f.hitstop == 0 and not f.frozen:
				var q: Vector3 = prev[bone_name]
				s.skate.append(Vector2(p.x - q.x, p.z - q.z).length() / DT * 100.0)
	_prev_soles[f] = now
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
		if p90 > SKATE_TARGET:
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
