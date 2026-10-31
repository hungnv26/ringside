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


func _ready() -> void:
	for side: String in SIDES:
		_feet[side] = _new_foot()


func _new_foot() -> Dictionary:
	return {planted = false, pos = Vector3.ZERO, basis = Basis.IDENTITY, swinging = false,
		from = Vector3.ZERO, from_basis = Basis.IDENTITY, u = 0.0, duration = 0.2, rest = 0.0,
		lifted = false}


func _bone(bone_name: String) -> int:
	if not _bones.has(bone_name):
		_bones[bone_name] = _skeleton.find_bone(bone_name)
	return _bones[bone_name]


func _process_modification_with_delta(delta: float) -> void:
	_skeleton = get_skeleton()
	if _skeleton == null:
		return
	solve(delta)


## Everything below works in world space for plants and skeleton space for bones.
func solve(delta: float) -> void:
	var sk := _skeleton
	var xf := sk.global_transform
	var root_world := xf.origin
	var target_weight := 0.0 if mode == Mode.OFF else 1.0
	var dt := 0.0 if frozen else delta
	_time += dt

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

	# Where the clip puts each foot this frame (world).
	var anim := {}
	for side: String in SIDES:
		var g := sk.get_bone_global_pose(_bone("foot_" + side))
		anim[side] = Transform3D(xf.basis.orthonormalized() * g.basis.orthonormalized(), xf * g.origin)

	var speed := _velocity.length()
	var step_time := lerpf(STEP_TIME_SLOW, STEP_TIME_FAST, clampf((speed - 1.2) / 3.0, 0.0, 1.0))
	for side: String in SIDES:
		var foot: Dictionary = _feet[side]
		var other: Dictionary = _feet["r" if side == "l" else "l"]
		var a: Transform3D = anim[side]
		foot.rest = maxf(foot.rest - dt, 0.0)
		if not foot.planted and not foot.swinging:
			# Following the clip (or just switched on): plant where it comes down.
			if not foot.lifted or a.origin.y < _clip_floor(side, a) + LAND_HEIGHT:
				_plant(foot, a)
			continue
		if foot.planted:
			# The clip lifting the foot (a kick, a jump squat's push) takes it.
			if a.origin.y > foot.pos.y + LIFT_HEIGHT:
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


## Height the clip's foot has when it stands on the floor (its planted height).
func _clip_floor(_side: String, a: Transform3D) -> float:
	return minf(a.origin.y, floor_y + 0.12)


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
