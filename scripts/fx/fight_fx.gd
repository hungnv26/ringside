class_name FightFx
extends Node3D
## Hit sparks, impact flashes, model hit-flash, knockdown dust and fight sounds, driven
## by FightManager / Fighter signals. Purely cosmetic: reads gameplay, never writes it.
## Heavy strikes, specials and supers leave a fading ribbon behind the striking limb
## (LimbTrail).
## Special moves add: fighter shouts (special / super / K.O.), motion trails while a
## travelling move is active, sparks along rising and flurry attacks, a ground-pound
## shockwave, projectile launch and impact bursts, and a big burst on super finishers.
##
## Phase 4 (docs/graphics-plan.md): hits throw streaks of sparks and an impact burst
## flipbook (assets/fx, tools/make_fx_art.py) sized by the move's damage, heavy hits puff
## shaded smoke; super finishers, K.O.s and heavy counters get an impact frame and a
## heat-distortion shockwave (ScreenFx); a super's freeze darkens everything but the
## fighter; knockdowns and wall splats raise dust in the stage's colour and throw debris;
## on sand (Stage.footprints) the fighters leave footprints. KOReplay replays the K.O.

const HEAVY_HITSTOP := 8 # moves with at least this much hitstop count as heavy
const SPARK_POOL := 8
const DUST_POOL := 3

const HIT_COLOR := Color(1.0, 0.75, 0.35)
const COUNTER_COLOR := Color(1.0, 0.35, 0.15)
const BLOCK_COLOR := Color(0.45, 0.75, 1.0)
const SUPER_COLOR := Color(1.0, 0.82, 0.3)
const FOCUS_COLOR := Color(1.0, 0.55, 0.15) # a focus power-up (Mira's Lakas Stance)
const REVERSAL_COLOR := Color(0.55, 1.0, 0.8) # a reversal stance catching a strike (Lian)
const TRAIL_COLOR := Color(0.8, 0.9, 1.0)
const DEBRIS_COLOR := Color(0.55, 0.45, 0.35)
const SMOKE_POOL := 4
const FOOTPRINTS := 28
const FOOTPRINT_SECONDS := 12.0
const FX_DIR := "res://assets/fx/"
## Fighter voices. Efforts on normal attacks: often on heavy ones, rarely on light ones,
## at most one per ATTACK_SHOUT_GAP per fighter. Pain on hits that land: always on heavy
## hits, counters and HURT_DAMAGE or more, sometimes on medium ones, at most one per
## HURT_GAP, so a long combo isn't a stream of grunts.
const ATTACK_SHOUT_HEAVY := 0.55
const ATTACK_SHOUT_LIGHT := 0.12
const ATTACK_SHOUT_GAP := 0.9
const HURT_DAMAGE := 80
const HURT_MEDIUM := 40
const HURT_MEDIUM_CHANCE := 0.35
const HURT_GAP := 0.45
const WALL_COLOR := Color(1.0, 0.95, 0.85) # the shock ring of a wall splat

var manager: Node
## Total effects spawned (lets tests confirm hits produce effects).
var spawned := 0

var _sparks: Array[GPUParticles3D] = []
var _dust: Array[GPUParticles3D] = []
var _next_spark := 0
var _next_dust := 0
var _flash_texture: Texture2D
var _smoke: Array[GPUParticles3D] = []
var _next_smoke := 0
var _debris_pool: Array[GPUParticles3D] = []
var _next_debris := 0
var screen: ScreenFx
var _footprints: Array[Decal] = []
var _next_footprint := 0
var _last_print := {} # [fighter, side] -> where that foot last left a print
## Per fighter: continuous emitters toggled each frame while a special is active.
var _trails := {} # Fighter -> GPUParticles3D (streaks behind travelling moves)
var _strike_sparks := {} # Fighter -> GPUParticles3D (sparks along rising/flurry hits)
var _limb_trails: Array[LimbTrail] = [] # ribbons behind heavy strikes, specials and supers


func setup(fight_manager: Node) -> void:
	manager = fight_manager
	_flash_texture = _make_radial_texture()
	for i in SPARK_POOL:
		_sparks.append(_make_sparks())
	for i in DUST_POOL:
		_dust.append(_make_dust())
	for i in SMOKE_POOL:
		_smoke.append(_make_smoke())
	for i in 3:
		_debris_pool.append(_make_debris())
	screen = ScreenFx.new()
	screen.name = "ScreenFx"
	add_child(screen)
	if manager.stage and manager.stage.get("footprints"):
		for i in FOOTPRINTS:
			_footprints.append(_make_footprint())
	# All effects are cosmetic: manager.cosmetic() skips them during rollback re-simulation.
	manager.hit_landed.connect(manager.cosmetic(_on_hit_landed))
	manager.super_flash.connect(manager.cosmetic(_on_super_flash))
	manager.reversal_landed.connect(manager.cosmetic(_on_reversal))
	manager.projectile_clashed.connect(manager.cosmetic(func(point: Vector3) -> void:
		spark(point, SUPER_COLOR, 1.4)
		Audio.sfx(&"hit_heavy", 0.0, 1.2)))
	manager.throw_landed.connect(manager.cosmetic(func(a: Fighter, d: Fighter) -> void:
		Audio.sfx(&"block", -4.0, 0.8)
		_shout(a, "attack")
		_shout(d, "hurt")))
	for fighter: Fighter in manager.fighters:
		fighter.attack_started.connect(manager.cosmetic(_on_attack_started.bind(fighter)))
		fighter.move_active.connect(manager.cosmetic(_on_move_active))
		fighter.knocked_out.connect(manager.cosmetic(func(f: Fighter) -> void: _shout(f, "ko")))
		fighter.combo_changed.connect(manager.cosmetic(func(hits: int) -> void:
			if hits == 5:
				Audio.voice("combo")))
		_trails[fighter] = _make_trail()
		if fighter.model:
			var limb_trail := LimbTrail.new(fighter, fighter.data.placeholder_color.lerp(Color.WHITE, 0.55))
			add_child(limb_trail)
			_limb_trails.append(limb_trail)
		_strike_sparks[fighter] = _make_strike_sparks()
		fighter.landed_hard.connect(manager.cosmetic(_on_landed_hard))
		fighter.throw_impact.connect(manager.cosmetic(_on_throw_impact))
		fighter.wall_hit.connect(manager.cosmetic(_on_wall_hit))
	_keep_materials()


## Hands the particle materials to GameState to hold, so the next fight doesn't rebuild
## their shaders while the loading screen waits (GameState.keep_materials).
func _keep_materials() -> void:
	var game_state := get_tree().root.get_node_or_null("GameState")
	if game_state == null:
		return
	var materials := []
	for particles: GPUParticles3D in find_children("*", "GPUParticles3D", true, false):
		materials.append(particles.process_material)
		materials.append(particles.material_override)
		if particles.draw_pass_1:
			for surface in particles.draw_pass_1.get_surface_count():
				materials.append(particles.draw_pass_1.surface_get_material(surface))
	game_state.keep_materials("fight_fx", materials.filter(func(m: Material) -> bool: return m != null))


func _on_hit_landed(attacker: Fighter, defender: Fighter, move: MoveData, result: Fighter.HitResult) -> void:
	var point: Vector3 = manager.last_hit_point
	var heavy := move.hitstop >= HEAVY_HITSTOP
	# Bigger hits throw bigger bursts: 0.6 for a jab up to 2.2 for the biggest specials.
	var weight := clampf(0.6 + move.damage / 90.0, 0.6, 2.2)
	var finisher := move.input.begins_with("~")
	var ko := defender.health <= 0
	if result != Fighter.HitResult.BLOCKED:
		if move.projectile_speed > 0.0:
			spark(point, move.projectile_color, 2.0) # energy burst
			_ring(point, move.projectile_color, 1.6, false)
		elif finisher: # super finisher
			spark(point, SUPER_COLOR, 2.4)
			_ring(point, SUPER_COLOR, 2.2, false)
			manager.camera.shake(0.45)
		# Impact frame and shockwave on the hits that matter most; a shockwave alone on
		# other heavy hits. Smoke off every heavy one.
		if finisher or ko or (heavy and result == Fighter.HitResult.COUNTER):
			screen.impact_frame(SUPER_COLOR.lerp(Color.WHITE, 0.6) if finisher else Color(1.0, 0.92, 0.85))
			screen.shockwave(point, 1.0)
		elif heavy:
			screen.shockwave(point, 0.55)
		if heavy or result == Fighter.HitResult.COUNTER:
			smoke(point, Color(0.85, 0.83, 0.8), 0.7 * weight)
		if finisher and not ko:
			manager.camera.finisher_slowmo()
	if result != Fighter.HitResult.BLOCKED and not ko:
		_hurt(defender, move, result)
	match result:
		Fighter.HitResult.BLOCKED:
			spark(point, BLOCK_COLOR, 0.6)
			Audio.sfx(&"block", -2.0)
			if defender.model:
				defender.model.flash(BLOCK_COLOR, 0.12)
		Fighter.HitResult.COUNTER:
			spark(point, COUNTER_COLOR, weight * 1.25)
			Audio.sfx(&"hit_heavy", 2.0, 0.9)
			if defender.model:
				defender.model.flash(COUNTER_COLOR, 0.2)
		_:
			spark(point, HIT_COLOR, weight)
			Audio.sfx(&"hit_heavy" if heavy else &"hit_light", 0.0 if heavy else -2.0)
			if defender.model:
				defender.model.flash(Color.WHITE, 0.16 if heavy else 0.1)


func _on_attack_started(move: MoveData, fighter: Fighter) -> void:
	if move.projectile_speed > 0.0:
		Audio.sfx(&"energy", -4.0)
	elif not move.super_move: # the super flash has its own sound
		Audio.sfx(&"swing_heavy" if move.hitstop >= HEAVY_HITSTOP else &"swing_light", -8.0)
	if move.is_special() and not move.super_move:
		_shout(fighter, "special")
	elif not move.super_move and move.projectile_speed <= 0.0:
		var heavy := move.hitstop >= HEAVY_HITSTOP
		if _since(fighter, &"shout_ms") >= ATTACK_SHOUT_GAP and Audio.chance(ATTACK_SHOUT_HEAVY if heavy else ATTACK_SHOUT_LIGHT):
			_shout(fighter, "attack")


## First active frame: launch flash, rising burst, ground-pound shockwave, or a focus
## power-up (a ring at the feet and rising sparks).
func _on_move_active(fighter: Fighter, move: MoveData) -> void:
	if move.projectile_speed > 0.0:
		spark(fighter.global_transform * Projectile.SPAWN_OFFSET, move.projectile_color, 1.0)
	if move.rise > 0.0:
		spark(fighter.global_transform * move.hitbox_offset, SUPER_COLOR if move.input.begins_with("~") else HIT_COLOR, 1.2)
	if move.impact_fx == &"shockwave":
		var point := fighter.global_position + fighter.forward * absf(move.hitbox_offset.z)
		point.y = 0.02
		_ring(point, Color(0.95, 0.85, 0.7), 3.4, true)
		dust(point)
		_debris(point)
		Audio.sfx(&"fall", 2.0, 0.7)
		manager.camera.shake(0.35)
	if move.impact_fx == &"focus":
		var feet := fighter.global_position + Vector3.UP * 0.03
		_ring(feet, FOCUS_COLOR, 2.2, true)
		spark(fighter.global_position + Vector3.UP * 1.0, FOCUS_COLOR, 1.5)
		Audio.sfx(&"super", -8.0, 1.35)


## Trails and strike sparks follow fighters while a qualifying move is active.
func _process(delta: float) -> void:
	_update_footprints()
	for limb_trail in _limb_trails:
		limb_trail.update(delta)
	for fighter: Fighter in _trails:
		var move := fighter.current_move
		var active := fighter.state == Fighter.State.ATTACK and move != null \
				and fighter.state_frame > move.startup and fighter.state_frame <= move.startup + move.active
		var trail: GPUParticles3D = _trails[fighter]
		trail.emitting = active and move.travel > 0.0
		if trail.emitting:
			trail.global_position = fighter.global_position + Vector3.UP * (0.25 if move.low_profile else 1.0)
		var sparks: GPUParticles3D = _strike_sparks[fighter]
		sparks.emitting = active and (move.rise > 0.0 or move.hits > 1)
		if sparks.emitting:
			sparks.global_position = fighter.global_transform * move.hitbox_offset
			(sparks.process_material as ParticleProcessMaterial).color = SUPER_COLOR if move.super_move or move.input.begins_with("~") else HIT_COLOR


## Footprints on sand (Stage.footprints): a print wherever a foot comes down at least
## FOOTPRINT_STEP from its last one, along the fighter's facing, fading out slowly.
const FOOTPRINT_STEP := 0.32


func _update_footprints() -> void:
	if _footprints.is_empty():
		return
	for fighter: Fighter in manager.fighters:
		if fighter.model == null or fighter.model.skeleton == null:
			continue
		var skeleton := fighter.model.skeleton
		for side in ["l", "r"]:
			var bone := skeleton.find_bone("foot_" + side)
			if bone < 0:
				continue
			var foot := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
			if foot.y > 0.13:
				continue
			var key := [fighter, side]
			var last: Vector3 = _last_print.get(key, Vector3(INF, 0, INF))
			if Vector2(foot.x - last.x, foot.z - last.z).length() < FOOTPRINT_STEP:
				continue
			_last_print[key] = foot
			var decal := _footprints[_next_footprint]
			_next_footprint = (_next_footprint + 1) % _footprints.size()
			decal.global_position = Vector3(foot.x, 0.0, foot.z) + fighter.forward * 0.05
			decal.basis = Basis(Vector3.UP, atan2(fighter.forward.x, fighter.forward.z))
			decal.modulate.a = 0.85
			decal.visible = true
			var tween := decal.create_tween()
			tween.tween_property(decal, "modulate:a", 0.0, FOOTPRINT_SECONDS).set_ease(Tween.EASE_IN)


func _make_footprint() -> Decal:
	var decal := Decal.new()
	decal.size = Vector3(0.13, 0.12, 0.3)
	decal.texture_albedo = load(FX_DIR + "footprint.png")
	decal.albedo_mix = 0.9
	decal.cull_mask = 1 # the ground, not the fighters
	decal.visible = false
	add_child(decal)
	return decal


## A reversal: a bright catch at the struck point, a ring, a sharp clap, the catcher's flash.
func _on_reversal(reverser: Fighter, _attacker: Fighter) -> void:
	var point: Vector3 = manager.last_hit_point
	spark(point, REVERSAL_COLOR, 1.3)
	_ring(point, REVERSAL_COLOR, 0.8, false)
	Audio.sfx(&"block", 0.0, 1.35)
	Audio.sfx(&"hit_heavy", -6.0, 0.8)
	if reverser.model:
		reverser.model.flash(REVERSAL_COLOR, 0.25)


## A fighter's shout, with their mouth moving to it. Each corner is its own speaker, so a
## mirror match keeps two voices.
func _shout(fighter: Fighter, kind: String, volume_db := 0.0) -> void:
	var player := Audio.shout(fighter.data.id, kind, volume_db, "p%d" % (manager.fighters.find(fighter) + 1))
	if player == null:
		return
	fighter.set_meta(&"shout_ms", Time.get_ticks_msec())
	if fighter.model:
		fighter.model.speak(player)


## A pain grunt from `defender` for a hit that landed (see HURT_DAMAGE).
func _hurt(defender: Fighter, move: MoveData, result: Fighter.HitResult) -> void:
	if _since(defender, &"hurt_ms") < HURT_GAP:
		return
	var big := move.hitstop >= HEAVY_HITSTOP or result == Fighter.HitResult.COUNTER or move.damage >= HURT_DAMAGE
	if big or (move.damage >= HURT_MEDIUM and Audio.chance(HURT_MEDIUM_CHANCE)):
		defender.set_meta(&"hurt_ms", Time.get_ticks_msec())
		_shout(defender, "hurt")


## Seconds since the time stamp `key` on `fighter` (a long time if never set).
func _since(fighter: Fighter, key: StringName) -> float:
	return (Time.get_ticks_msec() - int(fighter.get_meta(key, -100000))) / 1000.0


## Super start: a burst of golden sparks and a glow on the fighter, plus the flash sound.
func _on_super_flash(fighter: Fighter, _move: MoveData) -> void:
	spark(fighter.global_position + Vector3.UP * 1.1, SUPER_COLOR, 2.2)
	screen.darken_on(fighter, manager.SUPER_FREEZE_TICKS / 60.0)
	Audio.sfx(&"super", 0.0)
	_shout(fighter, "super", 2.0)
	if fighter.model:
		fighter.model.flash(SUPER_COLOR, 0.6)


func _on_landed_hard(fighter: Fighter) -> void:
	dust(fighter.global_position)
	smoke(Vector3(fighter.global_position.x, 0.15, fighter.global_position.z), _dust_color(), 1.3)
	_debris(Vector3(fighter.global_position.x, 0.05, fighter.global_position.z))
	Audio.sfx(&"fall", -2.0)


## Slammed into the edge: a burst and a shock ring standing on the (unseen) wall, dust
## off its foot, a heavy thud. Off the ropes: a lighter burst and a rope twang.
func _on_wall_hit(fighter: Fighter) -> void:
	var normal := fighter.wall_normal
	var point := fighter.global_position + Vector3.UP * maxf(1.0 - fighter.global_position.y * 0.5, 0.6) \
			+ normal * Fighter.BODY_RADIUS
	if fighter.edge_style == Fighter.EdgeStyle.ROPES:
		spark(point, HIT_COLOR, 0.9)
		Audio.sfx(&"block", -2.0, 0.6)
		Audio.sfx(&"fall", -8.0, 1.3)
	else:
		spark(point, HIT_COLOR, 1.5)
		_ring(point, WALL_COLOR, 1.1, false, normal)
		dust(Vector3(point.x, 0.0, point.z))
		smoke(Vector3(point.x, 0.6, point.z), _dust_color(), 1.1)
		_debris(point)
		screen.shockwave(point, 0.7)
		Audio.sfx(&"hit_heavy", 1.0, 0.7)
		Audio.sfx(&"fall", -1.0, 0.9)
	if fighter.model:
		fighter.model.flash(Color.WHITE, 0.18)


func _on_throw_impact(defender: Fighter) -> void:
	spark(defender.global_position + Vector3.UP * 1.1, HIT_COLOR, 1.4)
	Audio.sfx(&"hit_heavy", 1.0, 0.85)
	# Command grabs slam: dust and a shake; the super grab adds a gold shockwave.
	var grab := defender.opponent.grab_move
	if grab:
		var floor_point := Vector3(defender.global_position.x, 0.02, defender.global_position.z)
		dust(floor_point)
		manager.camera.shake(0.3)
		if grab.impact_fx == &"shockwave":
			_ring(floor_point, SUPER_COLOR, 3.4, true)
			spark(defender.global_position + Vector3.UP * 0.8, SUPER_COLOR, 2.4)
			manager.camera.shake(0.4)
	if defender.model:
		defender.model.flash(Color.WHITE, 0.16)


# --- Effects ---------------------------------------------------------------------

## Burst of spark streaks plus an impact burst (flipbook) at `point`. `size` ~0.5..2.4.
func spark(point: Vector3, color: Color, size: float) -> void:
	spawned += 1
	var p := _sparks[_next_spark]
	_next_spark = (_next_spark + 1) % _sparks.size()
	p.global_position = point
	p.amount_ratio = clampf(size / 1.8, 0.3, 1.0)
	var mat := p.process_material as ParticleProcessMaterial
	mat.color = color.lightened(0.15)
	mat.initial_velocity_min = 2.2 * size
	mat.initial_velocity_max = 6.0 * size
	mat.scale_min = 0.6 * sqrt(size)
	mat.scale_max = 1.3 * sqrt(size)
	p.restart()
	_impact_flash(point, color, size)


## A puff of shaded smoke or dust (lit by the stage) at `point`.
func smoke(point: Vector3, color: Color, size: float) -> void:
	spawned += 1
	var p := _smoke[_next_smoke]
	_next_smoke = (_next_smoke + 1) % _smoke.size()
	p.global_position = point
	var mat := p.process_material as ParticleProcessMaterial
	mat.color = color
	mat.scale_min = 1.6 * size
	mat.scale_max = 2.8 * size
	mat.emission_sphere_radius = 0.15 * size
	p.restart()


## The colour of the ground's dust on this stage (Stage.dust_color).
func _dust_color() -> Color:
	var c = manager.stage.get("dust_color") if manager.stage else null
	return c if c is Color else Color(0.75, 0.72, 0.68)


## Expanding ring: flat on the floor (ground pound), facing the camera (impacts), or
## lying in a wall whose outward normal is `facing`.
func _ring(point: Vector3, color: Color, size: float, flat: bool, facing := Vector3.ZERO) -> void:
	spawned += 1
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.5
	torus.rings = 32
	torus.ring_segments = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(color, 0.9)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	torus.material = mat
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.global_position = point
	if flat:
		ring.scale = Vector3(1.0, 0.15, 1.0)
	elif facing != Vector3.ZERO:
		ring.basis = Basis(Quaternion(Vector3.UP, facing.normalized())) # torus axis along the normal
	else:
		var camera := get_viewport().get_camera_3d()
		if camera:
			ring.look_at(camera.global_position, Vector3.UP)
			ring.rotate_object_local(Vector3.RIGHT, PI / 2.0) # torus axis toward the camera
	var start := ring.scale * 0.2
	var tween := ring.create_tween().set_parallel()
	tween.tween_property(ring, "scale", start * 5.0 * size, 0.35).from(start).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.35).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(ring.queue_free)


## Chunks of debris thrown up by a ground pound, a wall splat or a knockdown: grit and
## pebbles in the stage's dust colour, lit, falling back.
func _debris(point: Vector3) -> void:
	spawned += 1
	var p := _debris_pool[_next_debris]
	_next_debris = (_next_debris + 1) % _debris_pool.size()
	p.global_position = point
	(p.process_material as ParticleProcessMaterial).color = _dust_color().darkened(0.35)
	p.restart()


func dust(point: Vector3) -> void:
	spawned += 1
	var p := _dust[_next_dust]
	_next_dust = (_next_dust + 1) % _dust.size()
	(p.process_material as ParticleProcessMaterial).color = Color(_dust_color(), 0.55)
	p.global_position = point + Vector3.UP * 0.05
	p.restart()


## The impact burst: the 4 x 4 flipbook (assets/fx/impact.png) played over 0.2 s,
## additive, facing the camera, drawn over the fighters.
func _impact_flash(point: Vector3, color: Color, size: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 0.75 * size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.no_depth_test = true
	mat.albedo_texture = _impact_texture()
	mat.albedo_color = Color(color.lightened(0.25), 1.0)
	mat.uv1_scale = Vector3(0.25, 0.25, 1.0)
	quad.material = mat
	var flash := MeshInstance3D.new()
	flash.mesh = quad
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	flash.global_position = point
	flash.rotation.z = randf() * TAU # cosmetic randomness only
	var set_frame := func(f: float) -> void:
		var i := mini(int(f), 15)
		mat.uv1_offset = Vector3((i % 4) * 0.25, (i / 4) * 0.25, 0.0)
	set_frame.call(0.0)
	var tween := flash.create_tween()
	tween.tween_method(set_frame, 0.0, 15.99, 0.2)
	tween.tween_callback(flash.queue_free)


var _impact_tex: Texture2D


func _impact_texture() -> Texture2D:
	if _impact_tex == null:
		_impact_tex = load(FX_DIR + "impact.png")
	return _impact_tex


## Spark streaks: two crossed quads of the streak texture, stretched along their velocity
## (so they read from any side), gravity pulling them into arcs.
func _make_sparks() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.UP
	mat.spread = 180.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 7.0
	mat.gravity = Vector3(0, -14, 0)
	mat.damping_min = 6.0
	mat.damping_max = 11.0
	mat.scale_min = 0.7
	mat.scale_max = 1.4
	mat.particle_flag_align_y = true
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	mat.color_ramp = ramp
	var p := _make_emitter(mat, 48, 0.32, Vector2(0.035, 0.16))
	var draw_mat := (p.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	draw_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	draw_mat.albedo_texture = load(FX_DIR + "spark_streak.png")
	var cross := ArrayMesh.new()
	for k in 2:
		var quad := QuadMesh.new()
		quad.size = Vector2(0.035, 0.16)
		var arrays := quad.get_mesh_arrays()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in verts.size():
			verts[i] = Basis(Vector3.UP, k * PI / 2.0) * verts[i]
			normals[i] = Basis(Vector3.UP, k * PI / 2.0) * normals[i]
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		cross.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		cross.surface_set_material(k, draw_mat)
	p.draw_pass_1 = cross
	return p


## Shaded smoke: billboards of the smoke flipbook (assets/fx/smoke.png), lit by the stage,
## swelling and rising slowly over a second and a half.
func _make_smoke() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.15
	mat.direction = Vector3.UP
	mat.spread = 75.0
	mat.initial_velocity_min = 0.3
	mat.initial_velocity_max = 0.9
	mat.gravity = Vector3(0, 0.25, 0)
	mat.damping_min = 0.8
	mat.damping_max = 1.6
	mat.angle_min = -180.0
	mat.angle_max = 180.0
	mat.angular_velocity_min = -25.0
	mat.angular_velocity_max = 25.0
	mat.anim_speed_min = 1.0
	mat.anim_speed_max = 1.0
	var p := _make_emitter(mat, 10, 1.5, Vector2(0.5, 0.5))
	p.explosiveness = 0.9
	var draw_mat := (p.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	draw_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	draw_mat.albedo_texture = load(FX_DIR + "smoke.png")
	draw_mat.particles_anim_h_frames = 4
	draw_mat.particles_anim_v_frames = 4
	draw_mat.particles_anim_loop = false
	draw_mat.roughness = 1.0
	draw_mat.disable_receive_shadows = true
	return p


## Grit and pebbles: small lit chunks that fly out and fall.
func _make_debris() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.25
	mat.direction = Vector3.UP
	mat.spread = 55.0
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 4.5
	mat.gravity = Vector3(0, -12, 0)
	mat.scale_min = 0.4
	mat.scale_max = 1.2
	mat.angular_velocity_min = -400.0
	mat.angular_velocity_max = 400.0
	var p := _make_emitter(mat, 22, 0.9, Vector2(0.04, 0.04))
	var pebble := BoxMesh.new()
	pebble.size = Vector3(0.04, 0.03, 0.035)
	var pebble_mat := StandardMaterial3D.new()
	pebble_mat.vertex_color_use_as_albedo = true
	pebble_mat.roughness = 0.95
	pebble.material = pebble_mat
	p.draw_pass_1 = pebble
	return p


## Speed streaks left behind a travelling move (charges, slides).
func _make_trail() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.35
	mat.direction = Vector3.ZERO
	mat.spread = 180.0
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.3
	mat.gravity = Vector3.ZERO
	mat.scale_min = 0.8
	mat.scale_max = 1.6
	mat.color = Color(TRAIL_COLOR, 0.55)
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.7))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	mat.color_ramp = ramp
	return _make_continuous(mat, 60, 0.35, Vector2(0.3, 0.3))


## Sparks streaming off the striking limb during rising attacks and flurries.
func _make_strike_sparks() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.UP
	mat.spread = 60.0
	mat.initial_velocity_min = 1.0
	mat.initial_velocity_max = 3.0
	mat.gravity = Vector3(0, -4, 0)
	mat.scale_min = 0.6
	mat.scale_max = 1.2
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	mat.color_ramp = ramp
	return _make_continuous(mat, 50, 0.3, Vector2(0.08, 0.08))


func _make_continuous(mat: ParticleProcessMaterial, amount: int, lifetime: float, quad_size: Vector2) -> GPUParticles3D:
	var p := _make_emitter(mat, amount, lifetime, quad_size)
	p.one_shot = false
	p.explosiveness = 0.0
	p.emitting = false
	return p


func _make_dust() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_axis = Vector3.UP
	mat.emission_ring_radius = 0.5
	mat.emission_ring_inner_radius = 0.2
	mat.emission_ring_height = 0.05
	mat.direction = Vector3.UP
	mat.spread = 70.0
	mat.initial_velocity_min = 0.6
	mat.initial_velocity_max = 1.4
	mat.gravity = Vector3(0, 0.3, 0)
	mat.damping_min = 1.0
	mat.damping_max = 2.0
	mat.scale_min = 1.5
	mat.scale_max = 3.0
	mat.color = Color(0.75, 0.72, 0.68, 0.5)
	mat.anim_speed_min = 1.0
	mat.anim_speed_max = 1.0
	mat.angle_min = -180.0
	mat.angle_max = 180.0
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.6))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	mat.color_ramp = ramp
	var p := _make_emitter(mat, 24, 0.9, Vector2(0.25, 0.25))
	var draw_mat := p.draw_pass_1.surface_get_material(0) as StandardMaterial3D
	draw_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	draw_mat.albedo_texture = load(FX_DIR + "smoke.png")
	draw_mat.particles_anim_h_frames = 4
	draw_mat.particles_anim_v_frames = 4
	draw_mat.particles_anim_loop = false
	return p


func _make_emitter(mat: ParticleProcessMaterial, amount: int, lifetime: float, quad_size: Vector2) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = quad_size
	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw_mat.vertex_color_use_as_albedo = true
	draw_mat.albedo_texture = _flash_texture
	quad.material = draw_mat
	p.draw_pass_1 = quad
	add_child(p)
	return p


func _make_radial_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	gradient.add_point(0.3, Color(1, 1, 1, 0.8))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex
