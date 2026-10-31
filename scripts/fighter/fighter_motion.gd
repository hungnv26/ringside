class_name FighterMotion
extends SkeletonModifier3D
## The procedural layer on top of a fighter's clip (docs/movement-plan.md). Cosmetic only:
## it runs as the skeleton's last step before drawing, never touches the simulation, and
## Godot restores the clip pose after every frame, so nothing accumulates.
##
## Footwork (phase 1): each foot is planted in the world and stays there while the body
## moves; when the body has moved too far from it (or turned too far over it) the foot
## steps: it lifts, arcs and lands ahead of where the stance wants it. The clip still says
## where the feet belong (the stance) and when a move lifts one (a kick): a lifted foot
## follows the clip and is planted again where it comes down. Two-bone IK bends each leg to
## its foot, and the pelvis drops a little when a foot is out of reach.

enum Mode {
	OFF, ## feet follow the clip (airborne, falling, lying)
	GAIT, ## neutral movement: steps keep up with the body
	CLIP, ## the clip moves the feet (attacks, throws): only plants hold, steps when strained
}

const SIDES := ["l", "r"]
const LIFT_HEIGHT := 0.045 # clip foot this far above where it was planted: it is lifted
const LAND_HEIGHT := 0.02
const GAIT_STEP := 0.12 # metres a planted foot may lag behind its place in the stance
const CLIP_STEP := 0.30
const STEP_TURN := deg_to_rad(28.0) # a planted foot twisted this far off the stance steps
const STEP_TIME_SLOW := 0.2 # seconds a step takes walking
const STEP_TIME_FAST := 0.11 # and at dash speed
const STEP_HEIGHT := 0.07
const STEP_REST := 0.04 # a foot just landed doesn't step again sooner
const LANDING_LEAD := 0.55 # a step lands this fraction of its own time ahead of the body
const TELEPORT := 0.8 # metres in a frame: a reset, not movement
const MAX_PELVIS_DROP := 0.09
const WEIGHT_SPEED := 9.0 # how fast the footwork blends in and out (1/s)

## Inputs, set by the fighter every frame.
var mode := Mode.OFF
var frozen := false ## hitstop: hold everything where it is
var floor_y := 0.0
## Phase 3: where to look (world; usually the opponent's head) and how much (0 = the clip's own).
var look_target := Vector3.ZERO
var look_weight := 0.0
## 0 fresh .. 1 nearly out: deeper, quicker breathing and a lower guard in neutral.
var fatigue := 0.0
var neutral := false ## standing or moving in guard (fatigue shows only then)

## Head tracking: the share of the turn each bone takes, how far, how fast.
const LOOK_CHAIN := [["spine_03", 0.15], ["neck_01", 0.4], ["Head", 1.0]]
const LOOK_LIMIT := deg_to_rad(55.0)
const LOOK_SPEED := deg_to_rad(320.0) # the gaze direction turns at most this fast
## Hip weight: the torso tilts into acceleration on a spring (rocks back when stopping).
const LEAN_PER_ACCEL := 0.35 # degrees per m/s²
const LEAN_MAX := 9.0
const LEAN_STIFFNESS := 160.0
const LEAN_DAMPING := 16.0
const DIP_STIFFNESS := 220.0
const DIP_DAMPING := 18.0

var _skeleton: Skeleton3D
var _bones := {} # name -> index
var _feet := {} # side -> Dictionary
var _weight := 0.0
var _last_root := Vector3.ZERO
var _has_last := false
var _velocity := Vector3.ZERO # smoothed world velocity of the body
var _pelvis_drop := 0.0
var _time := 0.0
## Diagnostics for tools/check_motion.gd: the world position of each foot after solving.
var solved_feet := {}

var _look_dir := Vector3.ZERO # smoothed gaze direction (world), zero until first used
var _look_amount := 0.0
var _prev_velocity := Vector3.ZERO
var _lean := Vector3.ZERO # degrees about the world axis it points along (spring state)
var _lean_vel := Vector3.ZERO
var _dip := 0.0 # metres the pelvis sinks (spring state)
var _dip_vel := 0.0
var _was_airborne := false
var _breath := 0.0 # phase of the extra fatigue breathing
## Secondary motion (spring bones on hair and belt tails), built by SecondaryMotion.
var springs: SpringBoneSimulator3D

## Transitions (phase 2): inertialization. When the clip changes, the new clip plays at
## once and the difference from the pose shown last is added on top, decaying to nothing
## along a quintic that starts with the old pose's own velocity: the old motion carries on
## for a moment and settles into the new one, with no pop and no hitch.
var _last_rot := [] # per bone, the local rotation shown last frame (before IK)
var _prev_rot := [] # and the frame before
var _last_pelvis := Vector3.ZERO
var _prev_pelvis := Vector3.ZERO
var _last_dt := 1.0 / 60.0
var _pending := -1.0 # a transition asked for this frame: its duration
var _offsets := [] # per bone [axis, Vector4(A, B, C, half a0), v0, x0, t1] or null
var _pelvis_offset := [] # [direction, coefficients...] or empty
var _blend_t := 0.0


func _ready() -> void:
	for side: String in SIDES:
		_feet[side] = _new_foot()


## Starts a transition from the pose shown last frame, settling over `seconds`.
func start_transition(seconds: float) -> void:
	if _last_rot.is_empty() or seconds <= 0.0:
		return
	_pending = seconds


## Quintic decay of an offset x0 moving at v0, reaching 0 with no velocity or acceleration
## at t1 (Bollo, "Inertialization", GDC 2018). Returns [A, B, C, a0 / 2, v0, x0, t1].
static func _decay(x0: float, v0: float, duration: float) -> Array:
	if x0 < 1e-5:
		return []
	# Moving away from the new pose keeps going for a moment (follow-through), capped so
	# the offset can't more than double before it turns.
	var v := clampf(v0, -INF, x0 / maxf(duration, 1e-3) * 2.0)
	var t1 := duration
	if v < 0.0:
		t1 = minf(duration, -5.0 * x0 / v)
	t1 = maxf(t1, 1e-3)
	var a0 := maxf((-8.0 * v * t1 - 20.0 * x0) / (t1 * t1), 0.0)
	var a := -(a0 * t1 * t1 + 6.0 * v * t1 + 12.0 * x0) / (2.0 * pow(t1, 5.0))
	var b := (3.0 * a0 * t1 * t1 + 16.0 * v * t1 + 30.0 * x0) / (2.0 * pow(t1, 4.0))
	var c := -(3.0 * a0 * t1 * t1 + 12.0 * v * t1 + 20.0 * x0) / (2.0 * pow(t1, 3.0))
	return [a, b, c, a0 * 0.5, v, x0, t1]


static func _decay_at(k: Array, t: float) -> float:
	if k.is_empty() or t >= k[6]:
		return 0.0
	return (((k[0] * t + k[1]) * t + k[2]) * t + k[3]) * t * t + k[4] * t + k[5]


## Adds the decaying offset to the clip pose, then remembers what is shown.
func _blend_transition(dt: float) -> void:
	var sk := _skeleton
	var count := sk.get_bone_count()
	var pelvis := _bone("pelvis")
	if _pending > 0.0 and _last_rot.size() == count and _prev_rot.size() == count:
		_offsets.resize(count)
		var step := maxf(_last_dt, 1e-4)
		for i in count:
			var now := sk.get_bone_pose_rotation(i)
			var off := (_last_rot[i] as Quaternion) * now.inverse()
			if off.w < 0.0:
				off = -off
			var xyz := Vector3(off.x, off.y, off.z)
			var sin_half := xyz.length()
			if sin_half < 1e-5:
				_offsets[i] = null
				continue
			var axis := xyz / sin_half
			var x0 := 2.0 * atan2(sin_half, off.w)
			var prev := (_prev_rot[i] as Quaternion) * now.inverse()
			if prev.w < 0.0:
				prev = -prev
			var prev_x := 2.0 * atan2(Vector3(prev.x, prev.y, prev.z).dot(axis), prev.w)
			_offsets[i] = [axis, _decay(x0, (x0 - prev_x) / step, _pending)]
		var d0 := _last_pelvis - sk.get_bone_pose_position(pelvis)
		if d0.length() > 1e-5:
			var n := d0.normalized()
			var prev_d := (_prev_pelvis - sk.get_bone_pose_position(pelvis)).dot(n)
			_pelvis_offset = [n, _decay(d0.length(), (d0.length() - prev_d) / step, _pending)]
		else:
			_pelvis_offset = []
		_blend_t = 0.0
		_pending = -1.0
	elif _pending > 0.0:
		_pending = -1.0
	if not _offsets.is_empty():
		_blend_t += dt
		var live := false
		for i in mini(count, _offsets.size()):
			var o = _offsets[i]
			if o == null or (o[1] as Array).is_empty():
				continue
			var x := _decay_at(o[1], _blend_t)
			if x != 0.0:
				live = true
				sk.set_bone_pose_rotation(i, Quaternion(o[0], x) * sk.get_bone_pose_rotation(i))
		if not _pelvis_offset.is_empty():
			var x := _decay_at(_pelvis_offset[1], _blend_t)
			if x != 0.0:
				live = true
				sk.set_bone_pose_position(pelvis, sk.get_bone_pose_position(pelvis) + (_pelvis_offset[0] as Vector3) * x)
		if not live:
			_offsets.clear()
			_pelvis_offset = []
	if dt > 0.0 or _last_rot.size() != count:
		_prev_rot = _last_rot.duplicate()
		_prev_pelvis = _last_pelvis
		if _last_rot.size() != count:
			_last_rot.resize(count)
		for i in count:
			_last_rot[i] = sk.get_bone_pose_rotation(i)
		_last_pelvis = sk.get_bone_pose_position(pelvis)
		if _prev_rot.size() != count:
			_prev_rot = _last_rot.duplicate()
			_prev_pelvis = _last_pelvis
		if dt > 0.0:
			_last_dt = dt


func _new_foot() -> Dictionary:
	return {planted = false, pos = Vector3.ZERO, basis = Basis.IDENTITY, swinging = false,
		from = Vector3.ZERO, from_basis = Basis.IDENTITY, u = 0.0, duration = 0.2, rest = 0.0,
		lifted = false}


func _bone(bone_name: String) -> int:
	if not _bones.has(bone_name):
		_bones[bone_name] = _skeleton.find_bone(bone_name)
	return _bones[bone_name]


## Cost of the layer, for tools/check_motion.gd: microseconds spent in solve() and calls.
static var cost_usec := 0
static var cost_calls := 0


func _process_modification_with_delta(delta: float) -> void:
	_skeleton = get_skeleton()
	if _skeleton == null:
		return
	var started := Time.get_ticks_usec()
	solve(delta)
	cost_usec += Time.get_ticks_usec() - started
	cost_calls += 1


## Everything below works in world space for plants and skeleton space for bones.
func solve(delta: float) -> void:
	var sk := _skeleton
	var xf := sk.global_transform
	var root_world := xf.origin
	var target_weight := 0.0 if mode == Mode.OFF else 1.0
	var dt := 0.0 if frozen else delta
	_time += dt
	_blend_transition(dt)
	_keep_feet_above_floor()
	_body_dynamics(dt)
	_look(delta)

	# Body velocity from how the model moved (pushback, dashes, anything).
	if _has_last and root_world.distance_to(_last_root) > TELEPORT:
		_reset_feet()
	if _has_last and dt > 0.0:
		var v := (root_world - _last_root) / dt
		v.y = 0.0
		_velocity = _velocity.lerp(v, 1.0 - exp(-25.0 * dt))
	_last_root = root_world
	_has_last = true

	_weight = move_toward(_weight, target_weight, WEIGHT_SPEED * delta)
	if _weight <= 0.0:
		for side: String in SIDES:
			_feet[side].planted = false
			_feet[side].swinging = false
		_pelvis_drop = 0.0
		_record_feet()
		return

	# Where the clip puts each foot this frame (world), and how high its sole is off the floor.
	var anim := {}
	var sole := {}
	var scale := xf.basis.get_scale().y
	for side: String in SIDES:
		var g := sk.get_bone_global_pose(_bone("foot_" + side))
		anim[side] = Transform3D(xf.basis.orthonormalized() * g.basis.orthonormalized(), xf * g.origin)
		var h := INF
		for part: String in ["foot_", "ball_"]:
			var bone := _bone(part + side)
			var y := (xf * sk.get_bone_global_pose(bone).origin).y
			h = minf(h, y - floor_y - (sk.get_bone_global_rest(bone).origin.y + SOLE_BELOW_ORIGIN) * scale)
		sole[side] = h

	var speed := _velocity.length()
	var step_time := lerpf(STEP_TIME_SLOW, STEP_TIME_FAST, clampf((speed - 1.2) / 3.0, 0.0, 1.0))
	for side: String in SIDES:
		var foot: Dictionary = _feet[side]
		var other: Dictionary = _feet["r" if side == "l" else "l"]
		var a: Transform3D = anim[side]
		foot.rest = maxf(foot.rest - dt, 0.0)
		if not foot.planted and not foot.swinging:
			# Following the clip (or just switched on): plant where it comes down.
			if not foot.lifted or float(sole[side]) < LAND_HEIGHT:
				_plant(foot, a)
			continue
		if foot.planted:
			# The clip lifting the foot (a kick, a jump squat's push) takes it.
			if float(sole[side]) > LIFT_HEIGHT:
				foot.planted = false
				foot.lifted = true
				continue
			var home := _home(a, speed)
			var lag := Vector2(home.x - foot.pos.x, home.z - foot.pos.z).length()
			var twist := _yaw_between(foot.basis, a.basis)
			var limit := GAIT_STEP if mode == Mode.GAIT else CLIP_STEP
			# At speed (a dash) the feet skip: the second may leave once the first is half way.
			var other_ready: bool = other.planted or (other.swinging and other.u > 0.45 and speed > 2.5)
			if (lag > limit or twist > STEP_TURN) and foot.rest <= 0.0 and other_ready and dt > 0.0:
				if lag <= limit or _leads(side, home, anim) or _lag_of(other, anim["r" if side == "l" else "l"], speed) <= lag:
					foot.planted = false
					foot.swinging = true
					foot.from = foot.pos
					foot.from_basis = foot.basis
					foot.u = 0.0
					foot.duration = step_time
		elif foot.swinging:
			# The step quickens as the body does (a dash accelerates through its first step).
			foot.duration = minf(foot.duration, step_time)
			foot.u = minf(foot.u + dt / foot.duration, 1.0)
			if foot.u >= 1.0:
				var land: Vector3 = foot.land if foot.has("land") else _landing(a, foot, speed)
				land.y = a.origin.y
				foot.erase("land")
				foot.swinging = false
				foot.planted = true
				foot.pos = land
				foot.basis = a.basis
				foot.rest = STEP_REST

	# Targets for the IK (world).
	var targets := {}
	var swing_any := false
	for side: String in SIDES:
		var foot: Dictionary = _feet[side]
		var a: Transform3D = anim[side]
		if foot.planted:
			targets[side] = Transform3D(foot.basis, foot.pos)
		elif foot.swinging:
			swing_any = true
			# The landing spot is chosen while the foot travels and fixed once it comes down.
			if foot.u < 0.85 or not foot.has("land"):
				foot.land = _landing(a, foot, speed)
			var land: Vector3 = foot.land
			# Across in the first 85% of the step, then straight down onto the floor.
			var e := smoothstep(0.0, 1.0, minf(foot.u / 0.85, 1.0))
			var p: Vector3 = foot.from.lerp(land, e)
			p.y += STEP_HEIGHT * pow(sin(PI * foot.u), 0.6) * clampf(0.4 + speed * 0.25, 0.4, 1.0)
			var b: Basis = (foot.from_basis as Basis).slerp(a.basis, e)
			# Toe up a little mid-step.
			targets[side] = Transform3D(b, p)
		else:
			targets[side] = a

	# Pelvis: drop when a foot is out of reach; dip a touch while a foot is in the air.
	var drop := 0.0
	for side: String in SIDES:
		drop = maxf(drop, _drop_needed(side, targets[side].origin, xf))
	if swing_any:
		drop += 0.012
	_pelvis_drop = lerpf(_pelvis_drop, minf(drop, MAX_PELVIS_DROP), 1.0 - exp(-20.0 * delta))
	if _pelvis_drop > 0.0005:
		var pelvis := _bone("pelvis")
		var up_local: Vector3 = (sk.get_bone_global_pose(sk.get_bone_parent(pelvis)).basis.inverse() * Vector3.UP)
		sk.set_bone_pose_position(pelvis, sk.get_bone_pose_position(pelvis) - up_local * (_pelvis_drop * _weight / xf.basis.get_scale().y))

	var inv := xf.affine_inverse()
	var inv_basis := xf.basis.orthonormalized().inverse()
	for side: String in SIDES:
		var t: Transform3D = targets[side]
		_solve_leg(side, inv * t.origin, inv_basis * t.basis, _weight)
	_record_feet()


## The clips were authored for other proportions and can sink a sole into the floor: lift
## the body (the pelvis carries everything but the root) until the lowest sole is on it.
## Only ever lifts, so airborne poses are unaffected. Works on the pose actually shown
## (after the transition), so the lift eases with it.
const CONTACT_BONES := ["foot_l", "foot_r", "ball_l", "ball_r"]
const SOLE_BELOW_ORIGIN := 0.01

func _keep_feet_above_floor() -> void:
	var sk := _skeleton
	var lowest := INF
	for bone_name: String in CONTACT_BONES:
		var bone := _bone(bone_name)
		var rest := sk.get_bone_global_rest(bone).origin.y + SOLE_BELOW_ORIGIN
		lowest = minf(lowest, sk.get_bone_global_pose(bone).origin.y - rest)
	if lowest < 0.0:
		var pelvis := _bone("pelvis")
		var up_local: Vector3 = sk.get_bone_global_pose(sk.get_bone_parent(pelvis)).basis.inverse() * Vector3.UP
		sk.set_bone_pose_position(pelvis, sk.get_bone_pose_position(pelvis) + up_local * -lowest)


func _plant(foot: Dictionary, a: Transform3D) -> void:
	foot.planted = true
	foot.swinging = false
	foot.lifted = false
	foot.pos = a.origin
	foot.basis = a.basis


func _reset_feet() -> void:
	for side: String in SIDES:
		_feet[side] = _new_foot()
	_velocity = Vector3.ZERO
	_prev_velocity = Vector3.ZERO
	_lean = Vector3.ZERO
	_lean_vel = Vector3.ZERO
	_dip = 0.0
	_dip_vel = 0.0
	if springs:
		springs.reset()


## A jolt that sinks the pelvis (landing, a hit): metres per second downward.
func add_dip(speed: float) -> void:
	_dip_vel += speed


## Weight: the torso tilts into acceleration and rocks back when the body stops, the pelvis
## sinks on landing, and a tired fighter breathes harder with the guard lower.
func _body_dynamics(dt: float) -> void:
	if dt <= 0.0:
		return
	var sk := _skeleton
	var xf := sk.global_transform
	var airborne := mode == Mode.OFF and xf.origin.y > floor_y + 0.02
	if _was_airborne and not airborne and mode != Mode.OFF:
		add_dip(0.9)
	_was_airborne = airborne
	var accel := (_velocity - _prev_velocity) / dt
	_prev_velocity = _velocity
	var on_ground := mode != Mode.OFF
	var target := Vector3.ZERO
	if on_ground:
		target = accel.limit_length(LEAN_MAX / LEAN_PER_ACCEL) * LEAN_PER_ACCEL
	_lean_vel += (LEAN_STIFFNESS * (target - _lean) - LEAN_DAMPING * _lean_vel) * dt
	_lean += _lean_vel * dt
	_dip_vel += (-DIP_STIFFNESS * _dip - DIP_DAMPING * _dip_vel) * dt
	_dip = clampf(_dip + _dip_vel * dt, -0.03, 0.12)
	var inv_basis := xf.basis.orthonormalized().inverse()
	if _lean.length() > 0.05:
		# Tilt toward the acceleration: about the horizontal axis across it.
		var axis_world := Vector3.UP.cross(_lean.normalized())
		var axis := (inv_basis * axis_world).normalized()
		var degrees := _lean.length()
		_rotate_global(_bone("spine_01"), axis, deg_to_rad(degrees * 0.6))
		_rotate_global(_bone("spine_02"), axis, deg_to_rad(degrees * 0.4))
	if absf(_dip) > 0.0005:
		var pelvis := _bone("pelvis")
		var up_local: Vector3 = sk.get_bone_global_pose(sk.get_bone_parent(pelvis)).basis.inverse() * Vector3.UP
		sk.set_bone_pose_position(pelvis, sk.get_bone_pose_position(pelvis) - up_local * (_dip / xf.basis.get_scale().y))
	if neutral and fatigue > 0.01:
		_breath += dt * TAU / lerpf(1.6, 0.9, fatigue)
		var heave := (0.5 + 0.5 * sin(_breath)) * fatigue
		_rotate_global(_bone("spine_03"), Vector3.RIGHT, deg_to_rad(-2.2 * heave))
		_rotate_global(_bone("clavicle_l"), Vector3.BACK, deg_to_rad(2.0 * heave))
		_rotate_global(_bone("clavicle_r"), Vector3.BACK, deg_to_rad(-2.0 * heave))
		for side: String in SIDES:
			_rotate_global(_bone("upperarm_" + side), Vector3.RIGHT, deg_to_rad(8.0 * fatigue))
			_rotate_global(_bone("lowerarm_" + side), Vector3.RIGHT, deg_to_rad(5.0 * fatigue))


## The head (and a little of the neck and upper spine) turns toward look_target, the turn
## limited and its direction moving at a human speed.
func _look(delta: float) -> void:
	var sk := _skeleton
	var xf := sk.global_transform
	_look_amount = move_toward(_look_amount, look_weight, delta * 4.0)
	if _look_amount <= 0.001:
		_look_dir = Vector3.ZERO
		return
	var head := _bone("Head")
	var head_world := xf * sk.get_bone_global_pose(head).origin
	var want := look_target - head_world
	if want.length_squared() < 0.01:
		return
	want = want.normalized()
	if _look_dir == Vector3.ZERO:
		_look_dir = want
	else:
		var angle := _look_dir.angle_to(want)
		if angle > 1e-4:
			var axis := _look_dir.cross(want)
			if axis.length_squared() > 1e-10:
				_look_dir = _look_dir.rotated(axis.normalized(), minf(angle, LOOK_SPEED * delta)).normalized()
			else:
				_look_dir = want
	var inv_basis := xf.basis.orthonormalized().inverse()
	var to_target := (inv_basis * _look_dir).normalized()
	# The face's direction in the head bone's own frame, from the rest pose (+Z is forward).
	var face_local := sk.get_bone_global_rest(head).basis.orthonormalized().inverse() * Vector3.BACK
	for link: Array in LOOK_CHAIN:
		var bone := _bone(link[0])
		var face := (sk.get_bone_global_pose(head).basis.orthonormalized() * face_local).normalized()
		var angle := face.angle_to(to_target)
		if angle < 1e-4:
			break
		var axis := face.cross(to_target)
		if axis.length_squared() < 1e-10:
			break
		var allowed := minf(angle, LOOK_LIMIT)
		_rotate_global(bone, axis.normalized(), allowed * float(link[1]) * _look_amount)


## Rotates a bone (and so its children) by `angle` about a skeleton-space axis.
func _rotate_global(bone: int, axis: Vector3, angle: float) -> void:
	var sk := _skeleton
	var parent_bone := sk.get_bone_parent(bone)
	var parent := sk.get_bone_global_pose(parent_bone).basis.orthonormalized().get_rotation_quaternion() if parent_bone >= 0 else Quaternion.IDENTITY
	var global := sk.get_bone_global_pose(bone).basis.orthonormalized().get_rotation_quaternion()
	sk.set_bone_pose_rotation(bone, (parent.inverse() * (Quaternion(axis, angle) * global)).normalized())


## Where a foot belongs: its place in the stance, a little ahead in the direction of travel.
func _home(a: Transform3D, _speed: float) -> Vector3:
	return a.origin + _velocity * 0.05


func _landing(a: Transform3D, foot: Dictionary, _speed: float) -> Vector3:
	var remaining: float = (1.0 - foot.u) * foot.duration
	var p: Vector3 = a.origin + _velocity * (remaining + float(foot.duration) * LANDING_LEAD)
	p.y = a.origin.y
	return p


func _lag_of(foot: Dictionary, a: Transform3D, speed: float) -> float:
	if not foot.planted:
		return 0.0
	var home := _home(a, speed)
	return Vector2(home.x - foot.pos.x, home.z - foot.pos.z).length()


## True when this foot is the one on the side the body is travelling toward.
func _leads(side: String, home: Vector3, anim: Dictionary) -> bool:
	var other_side := "r" if side == "l" else "l"
	var other_home: Vector3 = anim[other_side].origin
	return (home - other_home).dot(_velocity) > 0.0


func _yaw_between(b1: Basis, b2: Basis) -> float:
	var f1 := Vector2(b1.z.x, b1.z.z)
	var f2 := Vector2(b2.z.x, b2.z.z)
	if f1.length_squared() < 1e-6 or f2.length_squared() < 1e-6:
		return 0.0
	return absf(f1.angle_to(f2))


## How far the pelvis must come down for the thigh to reach `target` (world).
func _drop_needed(side: String, target: Vector3, xf: Transform3D) -> float:
	var sk := _skeleton
	var scale := xf.basis.get_scale().y
	var hip := xf * sk.get_bone_global_pose(_bone("thigh_" + side)).origin
	var knee := xf * sk.get_bone_global_pose(_bone("calf_" + side)).origin
	var ankle := xf * sk.get_bone_global_pose(_bone("foot_" + side)).origin
	var reach := (hip.distance_to(knee) + knee.distance_to(ankle)) * 0.985
	var v := target - hip
	if v.length() <= reach:
		return 0.0
	var disc := v.y * v.y - (v.length_squared() - reach * reach)
	if disc < 0.0:
		return MAX_PELVIS_DROP
	return clampf(-v.y - sqrt(disc), 0.0, MAX_PELVIS_DROP) if scale > 0.0 else 0.0


## Two-bone IK in skeleton space: thigh and calf bend to put the ankle at `target`, the
## knee staying in the plane the clip bent it in; the foot takes `foot_basis`.
func _solve_leg(side: String, target: Vector3, foot_basis: Basis, weight: float) -> void:
	var sk := _skeleton
	var thigh := _bone("thigh_" + side)
	var calf := _bone("calf_" + side)
	var foot := _bone("foot_" + side)
	var original := [sk.get_bone_pose_rotation(thigh), sk.get_bone_pose_rotation(calf), sk.get_bone_pose_rotation(foot)]
	var a := sk.get_bone_global_pose(thigh).origin
	var b := sk.get_bone_global_pose(calf).origin
	var c := sk.get_bone_global_pose(foot).origin
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var to_target := target - a
	if to_target.length_squared() < 1e-6:
		return
	var d := clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var dir := to_target.normalized()
	var bend := (b - a) - dir * (b - a).dot(dir)
	if bend.length_squared() < 1e-6:
		bend = sk.get_bone_global_pose(_bone("pelvis")).basis.z
		bend = bend - dir * bend.dot(dir)
	bend = bend.normalized()
	var cos_a := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var knee := a + dir * (cos_a * l1) + bend * (sqrt(1.0 - cos_a * cos_a) * l1)
	_aim(thigh, b - a, knee - a)
	var b2 := sk.get_bone_global_pose(calf).origin
	var c2 := sk.get_bone_global_pose(foot).origin
	_aim(calf, c2 - b2, (a + dir * d) - b2)
	var parent := sk.get_bone_global_pose(calf).basis.orthonormalized()
	sk.set_bone_pose_rotation(foot, (parent.inverse() * foot_basis.orthonormalized()).get_rotation_quaternion())
	if weight < 1.0:
		var bones := [thigh, calf, foot]
		for i in 3:
			sk.set_bone_pose_rotation(bones[i], (original[i] as Quaternion).slerp(sk.get_bone_pose_rotation(bones[i]), weight))


## Rotates `bone` (skeleton space) so the direction `from` turns into `to`.
func _aim(bone: int, from: Vector3, to: Vector3) -> void:
	var sk := _skeleton
	if from.length_squared() < 1e-8 or to.length_squared() < 1e-8:
		return
	var turn := Quaternion(from.normalized(), to.normalized())
	var global := sk.get_bone_global_pose(bone).basis.orthonormalized().get_rotation_quaternion()
	var parent_bone := sk.get_bone_parent(bone)
	var parent := sk.get_bone_global_pose(parent_bone).basis.orthonormalized().get_rotation_quaternion() if parent_bone >= 0 else Quaternion.IDENTITY
	sk.set_bone_pose_rotation(bone, (parent.inverse() * (turn * global)).normalized())


func _record_feet() -> void:
	var xf := _skeleton.global_transform
	for side: String in SIDES:
		solved_feet[side] = xf * _skeleton.get_bone_global_pose(_bone("foot_" + side)).origin
