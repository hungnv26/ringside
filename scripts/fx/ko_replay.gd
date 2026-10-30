class_name KOReplay
extends Node
## A slow-motion replay of the K.O. from a cinematic angle, before the round card.
##
## While a round is live, every rendered frame records each fighter's skeleton (its world
## transform and every bone's pose) into a ring buffer of the last BUFFER_SECONDS of game
## time. When a fighter is knocked out, recording carries on for TAIL_SECONDS (the fall),
## then the buffer from LEAD_SECONDS before the K.O. plays back at SPEED: the recorded
## poses are laid over the live fighters each frame (after their own animation, so this
## node runs late), the camera orbits low around the K.O. (ActionCamera.start_replay), the
## HUD letterboxes with a "REPLAY" tag, and the K.O. hit's burst and impact frame fire again
## as the replay reaches it. Afterwards everything goes back to the live scene.
##
## Cosmetic only: real time, reads the fighters, never the simulation. The round-over phase
## is longer on K.O. rounds by FightManager.KO_REPLAY_TICKS in every mode (so match timing
## and saved replays stay deterministic); no replay shows during re-simulation, online play,
## training or with the action camera off (the round just holds a little longer).

signal finished

const BUFFER_SECONDS := 3.5
const LEAD_SECONDS := 1.4
const TAIL_SECONDS := 0.9
const SPEED := 0.5

var manager: Node
## [time, [[skeleton transform, positions, rotations], ...per fighter]] oldest first.
var _frames: Array = []
var _time := 0.0
var _ko_time := -1.0
var _ko_point := Vector3.ZERO
var _playing := false
var _play_time := 0.0
var _impact_fired := false
var _saved := [] # per fighter: skeleton local transform before the replay
## Replays shown (tests).
var shown := 0


func setup(fight_manager: Node) -> void:
	manager = fight_manager
	process_priority = 100 # after the fighters have posed their models
	for fighter: Fighter in manager.fighters:
		fighter.knocked_out.connect(manager.cosmetic(_on_knocked_out))


func playing() -> bool:
	return _playing


func _enabled() -> bool:
	return not (manager.is_online() or manager.is_training() or manager.is_replay()) \
		and manager.camera.mode != ActionCamera.Mode.OFF and DisplayServer.get_name() != "headless"


func _on_knocked_out(_loser: Fighter) -> void:
	if _ko_time >= 0.0 or not _enabled():
		return
	_ko_time = _time
	_ko_point = manager.last_hit_point


func _process(scaled_delta: float) -> void:
	if manager == null:
		return
	if _playing:
		_play(scaled_delta / maxf(Engine.time_scale, 0.01))
		return
	if manager.phase == manager.Phase.FIGHT or _ko_time >= 0.0:
		_time += scaled_delta
		_record()
	if _ko_time >= 0.0 and _time - _ko_time >= TAIL_SECONDS:
		_start()


func _record() -> void:
	var entry := []
	for fighter: Fighter in manager.fighters:
		var skeleton: Skeleton3D = fighter.model.skeleton if fighter.model else null
		if skeleton == null:
			entry.append(null)
			continue
		var positions := PackedVector3Array()
		var rotations: Array[Quaternion] = []
		for bone in skeleton.get_bone_count():
			positions.append(skeleton.get_bone_pose_position(bone))
			rotations.append(skeleton.get_bone_pose_rotation(bone))
		entry.append([skeleton.global_transform, positions, rotations])
	_frames.append([_time, entry])
	while not _frames.is_empty() and _time - _frames[0][0] > BUFFER_SECONDS:
		_frames.pop_front()


func _start() -> void:
	_playing = true
	_play_time = maxf(_ko_time - LEAD_SECONDS, _frames[0][0] if not _frames.is_empty() else _ko_time)
	_impact_fired = false
	shown += 1
	_saved.clear()
	for fighter: Fighter in manager.fighters:
		_saved.append(fighter.model.skeleton.transform if fighter.model and fighter.model.skeleton else Transform3D())
	manager.camera.start_replay(Vector3(_ko_point.x, 0.0, _ko_point.z))
	manager.hud.show_replay(true)


func _play(delta: float) -> void:
	_play_time += delta * SPEED
	var end_time: float = _frames[-1][0] if not _frames.is_empty() else _play_time
	if _play_time >= end_time:
		_stop()
		return
	if not _impact_fired and _play_time >= _ko_time:
		_impact_fired = true
		manager.fx.spark(_ko_point, Color(1.0, 0.75, 0.35), 2.0) # FightFx.HIT_COLOR
		manager.fx.screen.impact_frame(Color(1.0, 0.92, 0.85))
		manager.fx.screen.shockwave(_ko_point, 1.0)
		var audio := get_tree().root.get_node_or_null("Audio")
		if audio:
			audio.sfx(&"hit_heavy", 2.0, 0.7)
	# The two recorded frames around the play time, blended.
	var i := 0
	while i < _frames.size() - 2 and _frames[i + 1][0] < _play_time:
		i += 1
	var a: Array = _frames[i]
	var b: Array = _frames[mini(i + 1, _frames.size() - 1)]
	var t := clampf((_play_time - a[0]) / maxf(b[0] - a[0], 0.0001), 0.0, 1.0)
	for f in manager.fighters.size():
		var fighter: Fighter = manager.fighters[f]
		var pa = a[1][f]
		var pb = b[1][f]
		if pa == null or pb == null or fighter.model == null:
			continue
		var skeleton := fighter.model.skeleton
		skeleton.global_transform = (pa[0] as Transform3D).interpolate_with(pb[0], t)
		for bone in mini(skeleton.get_bone_count(), (pa[1] as PackedVector3Array).size()):
			skeleton.set_bone_pose_position(bone, (pa[1][bone] as Vector3).lerp(pb[1][bone], t))
			skeleton.set_bone_pose_rotation(bone, (pa[2][bone] as Quaternion).slerp(pb[2][bone], t))


func _stop() -> void:
	_playing = false
	_ko_time = -1.0
	_frames.clear()
	for f in manager.fighters.size():
		var fighter: Fighter = manager.fighters[f]
		if fighter.model and fighter.model.skeleton and f < _saved.size():
			fighter.model.skeleton.transform = _saved[f]
	manager.camera.stop_replay()
	manager.hud.show_replay(false)
	finished.emit()


## A new round (FightManager): drop anything recorded or pending.
func reset() -> void:
	if _playing:
		_stop()
	_frames.clear()
	_ko_time = -1.0
	_time = 0.0
