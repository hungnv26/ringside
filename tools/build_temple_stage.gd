extends SceneTree
## Builds the temple stage (res://scenes/stages/temple.tscn): a mountain temple courtyard
## at sunset. A raised stone platform for the fight, raked gravel, a vermilion torii gate
## framing the background, a five-tier pagoda and a temple hall beyond it, stone lanterns,
## cherry trees with drifting petals, low stone walls, and layered mountain ridges fading
## into the sunset haze under a Poly Haven sky. Re-run after changing anything below.
##
## Run: godot_console --headless --path . -s res://tools/build_temple_stage.gd
##
## Layout: platform top at y = 0 (10 m square; fight bounds ±3.6 m), gravel at y = -0.4.
## Everything tall sits outside the camera's reach (> 8.5 m from the center), so nothing
## needs hiding. Repeated geometry is merged into one mesh per material.

const OUTPUT := "res://scenes/stages/temple.tscn"
const TEX := "res://assets/stages/temple/textures/"
const SKY := "res://assets/stages/temple/belfast_sunset_puresky_2k.hdr"
const STAGE_SCRIPT := "res://scripts/stages/stage.gd"
const FLICKER_SCRIPT := "res://scripts/stages/fire_flicker.gd"
const AO_PATH := "res://assets/stages/temple/gravel_ao.res"

const PLATFORM := 5.0 # half size
const PLATFORM_HEIGHT := 0.4
const GRAVEL_Y := -PLATFORM_HEIGHT
const VERMILION := Color(0.78, 0.17, 0.08)
const SUN_COLOR := Color(1.0, 0.56, 0.28)
const BLOSSOM := Color(0.98, 0.72, 0.8)
## The sky's sun sits about 43° right of straight behind the gate, just above the
## horizon; the directional light comes from there (backlight and rim on the fighters).
const SKY_ROTATION_DEGREES := 0.0

var stage: Node3D
var _batches := {}
var _footprints := [] # everything standing on the gravel (contact shadows)
var mat_floor: StandardMaterial3D
var mat_stone_wall: StandardMaterial3D
var mat_gravel: StandardMaterial3D
var mat_roof: StandardMaterial3D
var mat_vermilion: StandardMaterial3D
var mat_black: StandardMaterial3D
var mat_white_wall: StandardMaterial3D
var mat_stone: StandardMaterial3D
var mat_lantern_glow: StandardMaterial3D
var mat_bark: StandardMaterial3D
var mat_blossom: StandardMaterial3D
var mat_gold: StandardMaterial3D
var mat_timber: StandardMaterial3D
var mat_cedar: StandardMaterial3D
var mat_paper: StandardMaterial3D
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 1868
	stage = Node3D.new()
	stage.name = "Temple"
	stage.set_script(load(STAGE_SCRIPT))
	stage.set("rope_line", 50.0) # nothing sits between the camera and the fight
	stage.set("music", &"temple")

	_make_materials()
	_build_environment()
	_build_lights()
	_build_ground()
	_build_torii()
	_build_pagoda(Vector3(-7.5, GRAVEL_Y, -21.0))
	_build_hall(Vector3(9.0, GRAVEL_Y, -19.0))
	_build_lanterns()
	_build_walls()
	_build_trees()
	_build_garden()
	_build_fallen_petals()
	_build_petals()
	_build_mountains()
	_build_lantern_flicker()
	_add(stage, StageFX.ambience([["res://assets/audio/ambience/birds.ogg", -15.0], ["res://assets/audio/ambience/wind.ogg", -21.0]]), "Sound") # ambient loops (StageAmbience)
	_flush_batches()
	_flush_roofs()
	_bake_contact_shadows()
	for v in _prop_sources.values():
		if v is Node:
			(v as Node).free()
	_add(stage, _marker(Vector3(-2, 0, 0)), "P1Spawn")
	_add(stage, _marker(Vector3(2, 0, 0)), "P2Spawn")

	var scene := PackedScene.new()
	var err := scene.pack(stage)
	if err == OK:
		err = ResourceSaver.save(scene, OUTPUT)
	print("saved ", OUTPUT, " err=", err)
	stage.free()
	quit()


func _make_materials() -> void:
	mat_floor = _textured("monastery_stone_floor", Color(1.0, 0.95, 0.9), 0.35)
	mat_stone_wall = _textured("japanese_stone_wall", Color(0.85, 0.82, 0.78), 0.5)
	mat_gravel = _textured("gravel_floor_03", Color(0.92, 0.9, 0.86), 0.5)
	mat_roof = _textured("grey_roof_tiles", Color(0.42, 0.44, 0.48), 0.6)
	mat_vermilion = _textured("red_plaster_weathered", Color(1.0, 0.42, 0.26), 0.5) # weathered lacquer
	mat_black = _material(Color(0.05, 0.05, 0.05), 0.0, 0.5)
	mat_white_wall = _textured("dojo/white_plaster_02", Color(0.95, 0.91, 0.84), 0.5)
	mat_timber = _textured("dark_planks", Color(0.72, 0.6, 0.52), 0.7)
	mat_cedar = _textured("dojo/japanese_cedar_planks", Color(0.5, 0.38, 0.3), 0.8)
	mat_paper = _material(Color(0.93, 0.9, 0.82), 0.0, 0.95) # shoji paper behind the lattices
	mat_stone = _textured("japanese_stone_wall", Color(0.7, 0.68, 0.64), 1.2)
	mat_lantern_glow = _emissive(Color(1.0, 0.7, 0.35), 3.0)
	mat_bark = _material(Color(0.2, 0.13, 0.1), 0.0, 0.9)
	mat_blossom = _material(BLOSSOM, 0.0, 0.8)
	mat_gold = _material(Color(0.85, 0.65, 0.25), 0.8, 0.35)


# --- Environment & lighting ------------------------------------------------------

func _build_environment() -> void:
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = load(SKY)
	sky_material.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.sky_rotation = Vector3(0, deg_to_rad(SKY_ROTATION_DEGREES), 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	# A warmer, punchier grade: the sky alone reads grey.
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.3
	env.adjustment_contrast = 1.08
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.05
	env.ssao_enabled = false # too costly on integrated GPUs (see CLAUDE.md)
	# Distance haze in the sunset's color (the mountains melt into it) and light shafts.
	env.fog_enabled = true
	env.fog_light_color = Color(0.95, 0.68, 0.55)
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.0
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.004
	env.volumetric_fog_albedo = Color(1.0, 0.85, 0.75)
	env.volumetric_fog_length = 30.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_add(stage, world_env, "WorldEnvironment")


func _build_lights() -> void:
	var lights := _add(stage, Node3D.new(), "Lights")
	# Low golden sun from behind-left, with shadows: long shadows across the platform.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-9, 137, 0) # from the sky's sun
	sun.light_energy = 2.2
	sun.light_color = SUN_COLOR
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 35.0
	sun.light_volumetric_fog_energy = 1.5
	_add(lights, sun, "Sun")
	# Cool sky fill from the opposite side so the shadow sides aren't black.
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 40, 0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.6, 0.65, 0.9)
	_add(lights, fill, "SkyFill")


# --- Ground ------------------------------------------------------------------------

func _build_ground() -> void:
	# Raked gravel all around.
	_batch(mat_gravel, Vector3(64, 0.2, 64), Transform3D(Basis(), Vector3(0, GRAVEL_Y - 0.1, 0)))
	# Raked lines: shallow grooves in rings around the platform.
	for ring in range(1, 8):
		var half := PLATFORM + 0.6 * ring
		for side in 4:
			var horizontal := side < 2
			var sign := -1.0 if side % 2 == 0 else 1.0
			var size := Vector3(half * 2.0, 0.015, 0.05) if horizontal else Vector3(0.05, 0.015, half * 2.0)
			var pos := Vector3(0, GRAVEL_Y + 0.004, sign * half) if horizontal else Vector3(sign * half, GRAVEL_Y + 0.004, 0)
			_batch(mat_stone, size, Transform3D(Basis(), pos))
	# The stone platform: paved top, stone-block sides, a darker lip.
	_batch(mat_floor, Vector3(PLATFORM * 2.0, 0.1, PLATFORM * 2.0), Transform3D(Basis(), Vector3(0, -0.05, 0)))
	_batch(mat_stone_wall, Vector3(PLATFORM * 2.0, PLATFORM_HEIGHT - 0.1, PLATFORM * 2.0), Transform3D(Basis(), Vector3(0, GRAVEL_Y + (PLATFORM_HEIGHT - 0.1) / 2.0, 0)))
	for side in 4:
		var horizontal := side < 2
		var sign := -1.0 if side % 2 == 0 else 1.0
		var size := Vector3(PLATFORM * 2.0 + 0.3, 0.08, 0.3) if horizontal else Vector3(0.3, 0.08, PLATFORM * 2.0 + 0.3)
		var pos := Vector3(0, 0.0, sign * PLATFORM) if horizontal else Vector3(sign * PLATFORM, 0.0, 0)
		_batch(mat_stone, size, Transform3D(Basis(), pos))
	# Steps down at the back, toward the gate.
	for i in 3:
		_batch(mat_stone, Vector3(3.0, 0.14, 0.4), Transform3D(Basis(), Vector3(0, -0.07 - i * 0.13, -PLATFORM - 0.2 - i * 0.4)))
	# Stone path from the steps to the gate.
	_batch(mat_floor, Vector3(2.6, 0.05, 6.0), Transform3D(Basis(), Vector3(0, GRAVEL_Y + 0.02, -PLATFORM - 4.0)))


# --- Torii gate ----------------------------------------------------------------------

func _build_torii() -> void:
	var z := -10.5
	var height := 6.2
	for x in [-2.7, 2.7]:
		var pillar := _cylinder(0.3, height, mat_vermilion, 20)
		pillar.position = Vector3(x, GRAVEL_Y + height / 2.0, z)
		_add(stage, pillar, "ToriiPillar%s" % ("L" if x < 0 else "R"))
		var base := _cylinder(0.38, 0.5, mat_black, 20)
		base.position = Vector3(x, GRAVEL_Y + 0.25, z)
		_add(stage, base, "ToriiBase%s" % ("L" if x < 0 else "R"))
	# Nuki (tie beam), gakuzuka (center strut) with a name plaque, kasagi (top beam).
	_batch(mat_vermilion, Vector3(7.4, 0.32, 0.3), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height - 1.35, z)))
	_batch(mat_vermilion, Vector3(0.3, 0.9, 0.25), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height - 0.75, z)))
	_batch(mat_black, Vector3(0.7, 0.95, 0.06), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height - 0.8, z + 0.16)))
	_batch(mat_gold, Vector3(0.55, 0.8, 0.02), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height - 0.8, z + 0.2)))
	_batch(mat_vermilion, Vector3(7.8, 0.4, 0.5), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height - 0.1, z)))
	_batch(mat_black, Vector3(8.6, 0.22, 0.62), Transform3D(Basis(), Vector3(0, GRAVEL_Y + height + 0.2, z)))
	# Upswept ends of the top beam.
	for x in [-1.0, 1.0]:
		var tip := Transform3D(Basis(Vector3(0, 0, 1), x * 0.18), Vector3(x * 4.6, GRAVEL_Y + height + 0.32, z))
		_batch(mat_black, Vector3(1.1, 0.22, 0.62), tip)


# --- Buildings -----------------------------------------------------------------------

## Five-tier pagoda: stone base, tiers shrinking upward, each with wide eaves, and a
## bronze spire with rings.
func _build_pagoda(at: Vector3) -> void:
	_batch(mat_stone_wall, Vector3(6.0, 1.0, 6.0), Transform3D(Basis(), at + Vector3(0, 0.5, 0)))
	var y := 1.0
	var width := 4.4
	for tier in 5:
		var body := 1.7 if tier == 0 else 1.25
		_batch(mat_white_wall, Vector3(width, body, width), Transform3D(Basis(), at + Vector3(0, y + body / 2.0, 0)))
		for x in [-0.5, 0.5]: # corner posts
			for zz in [-0.5, 0.5]:
				_batch(mat_vermilion, Vector3(0.18, body, 0.18), Transform3D(Basis(), at + Vector3(x * width, y + body / 2.0, zz * width)))
		for side in 4:
			var face := Basis(Vector3.UP, side * PI / 2.0)
			var out := face * Vector3(0, 0, 1)
			var wall := at + out * (width / 2.0) + Vector3.UP * y
			# Timber bands at the foot and head of the wall, a lattice door in the middle.
			_batch(mat_timber, Vector3(width + 0.04, 0.14, 0.08), Transform3D(face, wall + Vector3.UP * 0.07 + out * 0.03))
			_batch(mat_timber, Vector3(width + 0.04, 0.16, 0.08), Transform3D(face, wall + Vector3.UP * (body - 0.08) + out * 0.03))
			_lattice(Transform3D(face, wall + Vector3.UP * (0.14 + (body - 0.3) / 2.0) + out * 0.02), minf(1.1, width * 0.32), body - 0.34)
			for k in [-1.0, 1.0]: # vermilion posts either side of the door
				_batch(mat_vermilion, Vector3(0.12, body - 0.3, 0.1), Transform3D(face, wall + face * Vector3(k * (minf(1.1, width * 0.32) / 2.0 + 0.06), 0.14 + (body - 0.3) / 2.0, 0.04)))
			# Rafter ends under the eave, and a bracket block on each corner post.
			_rafters(Transform3D(face, wall + Vector3.UP * (body + 0.16)), width + 2.2, 1.25)
			for k in [-0.5, 0.5]:
				_batch(mat_cedar, Vector3(0.3, 0.16, 0.3), Transform3D(face, wall + face * Vector3(k * width, body + 0.08, 0.0)))
		y += body
		_batch(mat_vermilion, Vector3(width + 0.5, 0.2, width + 0.5), Transform3D(Basis(), at + Vector3(0, y + 0.1, 0)))
		var eave := (width + 2.6) / 2.0
		var last := tier == 4
		var top := 0.18 if last else maxf(width / 2.0 - 0.15, 0.2)
		_hip_roof(at + Vector3(0, y + 0.22, 0), Vector2(eave, eave), Vector2(top, top), 1.3 if last else 0.63, 0.32)
		y += 0.8
		width -= 0.6
	var spire := _cylinder(0.08, 3.2, mat_gold, 8)
	spire.position = at + Vector3(0, y + 1.6, 0)
	_add(stage, spire, "PagodaSpire")
	for r in 5:
		var ring := _cylinder(0.32 - r * 0.03, 0.08, mat_gold, 12)
		ring.position = at + Vector3(0, y + 0.6 + r * 0.45, 0)
		_add(stage, ring, "SpireRing%d" % r)


## Temple hall: stone base, vermilion pillars, white walls, a big tiled hip roof.
func _build_hall(at: Vector3) -> void:
	_batch(mat_stone_wall, Vector3(11.0, 1.0, 7.5), Transform3D(Basis(), at + Vector3(0, 0.5, 0)))
	_batch(mat_white_wall, Vector3(9.0, 3.2, 5.6), Transform3D(Basis(), at + Vector3(0, 2.6, 0)))
	for i in 6:
		var x := -4.5 + i * 1.8
		_batch(mat_vermilion, Vector3(0.3, 3.4, 0.3), Transform3D(Basis(), at + Vector3(x, 2.7, 2.95)))
	_batch(mat_vermilion, Vector3(9.6, 0.35, 0.4), Transform3D(Basis(), at + Vector3(0, 4.35, 2.95)))
	# The front: a veranda, timber sill and head beams, and in each bay a
	# timber dado under a shoji lattice; the middle bay is a pair of lattice doors.
	_batch(mat_cedar, Vector3(10.4, 0.12, 1.3), Transform3D(Basis(), at + Vector3(0, 1.06, 3.35)))
	_batch(mat_timber, Vector3(9.1, 0.16, 0.1), Transform3D(Basis(), at + Vector3(0, 1.2, 2.84)))
	_batch(mat_timber, Vector3(9.1, 0.22, 0.12), Transform3D(Basis(), at + Vector3(0, 3.9, 2.85)))
	for bay in 5:
		var x := -3.6 + bay * 1.8
		var bay_xform := Transform3D(Basis(), at + Vector3(x, 0, 2.82))
		if bay == 2:
			_lattice(bay_xform.translated(Vector3(0, 2.5, 0)), 1.45, 2.4)
			_batch(mat_timber, Vector3(0.06, 2.4, 0.06), bay_xform.translated(Vector3(0, 2.5, 0.06)))
		else:
			_batch(mat_cedar, Vector3(1.48, 0.8, 0.05), bay_xform.translated(Vector3(0, 1.68, 0.0)))
			_lattice(bay_xform.translated(Vector3(0, 2.95, 0)), 1.45, 1.75)
	# Bracket blocks on the pillars, rafter ends under the front and back eaves.
	for i in 6:
		var x := -4.5 + i * 1.8
		_batch(mat_cedar, Vector3(0.5, 0.18, 0.5), Transform3D(Basis(), at + Vector3(x, 4.62, 2.95)))
		_batch(mat_cedar, Vector3(0.9, 0.16, 0.36), Transform3D(Basis(), at + Vector3(x, 4.79, 2.95)))
	for side in [0, 2]:
		var face := Basis(Vector3.UP, side * PI / 2.0)
		_rafters(Transform3D(face, at + face * Vector3(0, 4.4, 3.0)), 12.4, 1.5)
	# Hip roof: four slopes up to a ridge, the eave corners swept up.
	_hip_roof(at + Vector3(0, 4.5, 0), Vector2(6.6, 4.8), Vector2(4.75, 0.0), 1.95, 0.4)
	_batch(mat_black, Vector3(9.5, 0.45, 0.5), Transform3D(Basis(), at + Vector3(0, 6.45, 0)))
	for side in [-1.0, 1.0]: # ridge-end ornaments
		_batch(mat_gold, Vector3(0.4, 0.8, 0.4), Transform3D(Basis(), at + Vector3(side * 4.8, 6.9, 0)))


var _roofs := SurfaceTool.new()
var _roof_count := 0


## A tiled hip roof, its eave rectangle `eave` (half extents in X and Z) at `base`, rising
## `height` to a top rectangle `top` (Z = 0 makes a ridge; both small, a point). Each slope
## sags a little in the middle, and the eave dips toward the middle of each side so the
## corners sweep up by `lift`. Collected into one mesh (_flush_roofs).
func _hip_roof(base: Vector3, eave: Vector2, top: Vector2, height: float, lift: float) -> void:
	if _roof_count == 0:
		_roofs.begin(Mesh.PRIMITIVE_TRIANGLES)
	_roof_count += 1
	const ALONG := 12
	const UP := 4
	var corners_low := [Vector3(-eave.x, 0, eave.y), Vector3(eave.x, 0, eave.y), Vector3(eave.x, 0, -eave.y), Vector3(-eave.x, 0, -eave.y)]
	var corners_high := [Vector3(-top.x, height, top.y), Vector3(top.x, height, top.y), Vector3(top.x, height, -top.y), Vector3(-top.x, height, -top.y)]
	for side in 4:
		var a: Vector3 = corners_low[side]
		var b: Vector3 = corners_low[(side + 1) % 4]
		var a2: Vector3 = corners_high[side]
		var b2: Vector3 = corners_high[(side + 1) % 4]
		var mid := (a + b) * 0.5
		var outward := Vector3(mid.x, 0.0, mid.z).normalized()
		var grid := []
		for j in UP + 1:
			var row := []
			var s_up := float(j) / UP
			for i in ALONG + 1:
				var t := float(i) / ALONG
				var low := a.lerp(b, t) + Vector3.UP * lift * pow(absf(2.0 * t - 1.0), 2.5)
				var high := a2.lerp(b2, t)
				var p := low.lerp(high, s_up) - Vector3.UP * 0.1 * height * sin(PI * s_up)
				row.append(base + p)
			grid.append(row)
		for j in UP:
			for i in ALONG:
				var p00: Vector3 = grid[j][i]
				var p10: Vector3 = grid[j][i + 1]
				var p01: Vector3 = grid[j + 1][i]
				var p11: Vector3 = grid[j + 1][i + 1]
				var n := (p10 - p00).cross(p01 - p00)
				if n.dot(outward + Vector3.UP) < 0.0:
					_roofs.add_vertex(p00); _roofs.add_vertex(p10); _roofs.add_vertex(p11)
					_roofs.add_vertex(p00); _roofs.add_vertex(p11); _roofs.add_vertex(p01)
				else:
					_roofs.add_vertex(p00); _roofs.add_vertex(p11); _roofs.add_vertex(p10)
					_roofs.add_vertex(p00); _roofs.add_vertex(p01); _roofs.add_vertex(p11)


func _flush_roofs() -> void:
	if _roof_count == 0:
		return
	_roofs.generate_normals()
	var mat := mat_roof.duplicate() as StandardMaterial3D
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED # the undersides of the eaves
	_roofs.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.mesh = _roofs.commit()
	_add(stage, mi, "Roofs")


## A shoji lattice centred on `xform` (facing its +Z): a paper backing and a grid of thin
## cedar bars, `width` by `height`.
func _lattice(xform: Transform3D, width: float, height: float) -> void:
	_batch(mat_paper, Vector3(width, height, 0.03), xform)
	_batch(mat_cedar, Vector3(width + 0.08, 0.08, 0.06), xform.translated_local(Vector3(0, height / 2.0, 0.02)))
	_batch(mat_cedar, Vector3(width + 0.08, 0.08, 0.06), xform.translated_local(Vector3(0, -height / 2.0, 0.02)))
	var columns := maxi(2, roundi(width / 0.16))
	for c in columns + 1:
		_batch(mat_cedar, Vector3(0.035, height, 0.04), xform.translated_local(Vector3(-width / 2.0 + c * width / columns, 0, 0.03)))
	var rows := maxi(2, roundi(height / 0.26))
	for r in range(1, rows):
		_batch(mat_cedar, Vector3(width, 0.03, 0.04), xform.translated_local(Vector3(0, -height / 2.0 + r * height / rows, 0.03)))


## Rafter ends under an eave: square timbers along `xform`'s X, `length` long in all,
## reaching `reach` metres out along its +Z, with a fascia board across their ends.
func _rafters(xform: Transform3D, length: float, reach: float) -> void:
	var count := roundi(length / 0.32)
	for i in count + 1:
		_batch(mat_timber, Vector3(0.08, 0.09, reach), xform.translated_local(Vector3(-length / 2.0 + i * length / count, 0, reach / 2.0)))
	_batch(mat_timber, Vector3(length + 0.1, 0.16, 0.06), xform.translated_local(Vector3(0, 0.02, reach)))


# --- Lanterns, walls, trees ------------------------------------------------------------

## Stone lanterns (toro): base, post, glowing fire box, roof, finial.
func _build_lanterns() -> void:
	var spots := [Vector3(-6.0, GRAVEL_Y, -6.0), Vector3(6.0, GRAVEL_Y, -6.0), Vector3(-6.2, GRAVEL_Y, -12.5),
		Vector3(6.2, GRAVEL_Y, -12.5), Vector3(-9.5, GRAVEL_Y, 1.0), Vector3(9.5, GRAVEL_Y, 1.0)]
	for i in spots.size():
		var at: Vector3 = spots[i]
		_add_mesh(_hex(0.55, 0.3, mat_stone), at + Vector3(0, 0.15, 0), "LanternBase%d" % i)
		_add_mesh(_hex(0.18, 1.0, mat_stone), at + Vector3(0, 0.8, 0), "LanternPost%d" % i)
		_add_mesh(_hex(0.42, 0.18, mat_stone), at + Vector3(0, 1.39, 0), "LanternShelf%d" % i)
		_add_mesh(_hex(0.3, 0.42, mat_lantern_glow), at + Vector3(0, 1.69, 0), "LanternFire%d" % i)
		var roof := CylinderMesh.new()
		roof.top_radius = 0.08
		roof.bottom_radius = 0.62
		roof.height = 0.42
		roof.radial_segments = 6
		roof.material = mat_stone
		_add_mesh(roof, at + Vector3(0, 2.11, 0), "LanternRoof%d" % i)
		var finial := SphereMesh.new()
		finial.radius = 0.1
		finial.height = 0.2
		finial.material = mat_stone
		_add_mesh(finial, at + Vector3(0, 2.38, 0), "LanternFinial%d" % i)
		if i < 4:
			var glow := OmniLight3D.new()
			glow.position = at + Vector3(0, 1.7, 0)
			glow.light_color = Color(1.0, 0.65, 0.35)
			glow.light_energy = 1.2
			glow.omni_range = 4.0
			_add(stage, glow, "LanternLight%d" % i)


## Low stone walls bounding the courtyard, open at the back for the gate path.
func _build_walls() -> void:
	var r := 15.0
	var height := 1.2
	for side in 4:
		var basis := Basis(Vector3.UP, side * PI / 2.0)
		var out := basis * Vector3(0, 0, 1)
		var tangent := basis * Vector3(1, 0, 0)
		var gap := side == 2 # back (-Z): open for the path to the gate
		for segment: float in ([-1.0, 1.0] if gap else [0.0]):
			var length: float = r * 2.0 if not gap else r - 2.5
			var along: float = segment * (r + 2.5) / 2.0 if gap else 0.0
			var center: Vector3 = out * r + tangent * along + Vector3.UP * (GRAVEL_Y + height / 2.0)
			_batch(mat_stone_wall, Vector3(length, height, 0.6), Transform3D(basis, center))
			_batch(mat_roof, Vector3(length, 0.18, 0.9), Transform3D(basis, center + Vector3.UP * (height / 2.0 + 0.09)))


## Cherry trees: Poly Haven's Jacaranda Tree turned into a cherry by
## tools/blender/build_cherry_tree.py (decimated trunk and branches, blossom cards where its
## leaves were). The meshes are saved once with the game's materials: the bark tinted to a
## cherry's dark red-brown, the blossom in the wind (foliage_wind.gdshader).
func _build_trees() -> void:
	var meshes := _cherry_meshes()
	var spots := [Vector3(-10.5, GRAVEL_Y, -7.0), Vector3(11.0, GRAVEL_Y, -8.5), Vector3(-12.0, GRAVEL_Y, -13.0),
		Vector3(12.5, GRAVEL_Y, -3.0), Vector3(-11.5, GRAVEL_Y, 3.5), Vector3(4.5, GRAVEL_Y, -14.5)]
	for i in spots.size():
		var tree := Node3D.new()
		tree.position = spots[i]
		tree.rotation.y = _rng.randf() * TAU
		tree.scale = Vector3.ONE * _rng.randf_range(0.85, 1.1)
		_add(stage, tree, "CherryTree%d" % i)
		for m: Mesh in meshes:
			var mi := MeshInstance3D.new()
			mi.mesh = m
			if m.resource_name == "Blossom":
				# Thousands of alpha-tested cards in every shadow pass cost more than the rest of
				# the stage together (docs/graphics-plan.md); the bark still casts the long shadows.
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_add(tree, mi, m.resource_name)
		var at: Vector3 = spots[i]
		_footprints.append([at.x - 0.3, at.z - 0.3, at.x + 0.3, at.z + 0.3, 3.0]) # the trunk only


const CHERRY_SOURCE := "res://assets/stages/temple/cherry/cherry_tree.gltf"
const CHERRY_DIR := "res://assets/stages/temple/cherry/"


## The cherry tree's meshes with the game's materials, saved next to the source (a mesh
## inside an imported glTF can't be given materials from another scene).
func _cherry_meshes() -> Array[Mesh]:
	var source: Node = (load(CHERRY_SOURCE) as PackedScene).instantiate()
	var out: Array[Mesh] = []
	for mi: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		var mesh := mi.mesh.duplicate() as ArrayMesh
		var is_blossom := false
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat and "Blossom" in mat.resource_name:
				is_blossom = true
				var wind := ShaderMaterial.new()
				wind.shader = load("res://assets/stages/shared/foliage_wind.gdshader")
				wind.set_shader_parameter("albedo_tex", (mat as BaseMaterial3D).albedo_texture)
				mesh.surface_set_material(i, wind)
			elif mat is BaseMaterial3D:
				var bark := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
				bark.albedo_color = Color(0.62, 0.48, 0.44) # cherry bark: darker, redder
				mesh.surface_set_material(i, bark)
		mesh.resource_name = "Blossom" if is_blossom else "Bark%d" % out.size()
		var path := CHERRY_DIR + mesh.resource_name.to_snake_case() + ".res"
		ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
		var saved := load(path) as Mesh
		saved.resource_name = mesh.resource_name
		out.append(saved)
	source.free()
	return out


const PROPS := "res://assets/stages/temple/props/"
var _prop_sources := {}


## Mossy rocks set in the gravel (dry-garden groups with ferns at their feet), shrubs along
## the inside of the walls, weeds at the wall bases. Poly Haven models (CC0); each variant's
## mesh is saved on its own (the source files hold several side by side).
func _build_garden() -> void:
	var garden := _add(stage, Node3D.new(), "Garden")
	var groups := [Vector2(-8.6, -3.2), Vector2(8.2, -4.6), Vector2(-7.4, -12.2), Vector2(7.8, -12.0), Vector2(-9.0, 6.5), Vector2(9.2, 5.5)]
	var big := ["rock_moss_set_02_rock10", "rock_moss_set_02_rock11", "rock_moss_set_02_rock07", "rock_moss_set_02_rock13"]
	var small := ["rock_moss_set_02_rock08", "rock_moss_set_02_rock09", "rock_moss_set_02_rock12"]
	var ferns := ["fern_02_a", "fern_02_b", "fern_02_c", "fern_02_d"]
	var n := 0
	for g: Vector2 in groups:
		var centre := Vector3(g.x, GRAVEL_Y, g.y)
		_place(garden, "rock_moss_set_02", big[n % big.size()], centre, _rng.randf_range(0.65, 0.85), "Rock%d" % n)
		for k in 2:
			var off := Vector3(_rng.randf_range(-1.6, 1.6), 0, _rng.randf_range(-1.2, 1.2))
			_place(garden, "rock_moss_set_02", small[(n + k) % small.size()], centre + off, _rng.randf_range(0.35, 0.55), "Rock%d_%d" % [n, k])
		for k in 3:
			var off := Vector3(_rng.randf_range(-1.3, 1.3), 0, _rng.randf_range(-1.0, 1.0))
			_place(garden, "fern_02", ferns[(n + k) % ferns.size()], centre + off, _rng.randf_range(0.8, 1.2), "Fern%d_%d" % [n, k])
		n += 1
	var shrubs := ["shrub_02_a", "shrub_02_b", "shrub_02_c", "shrub_02_d"]
	var spots := []
	for x in [-12.8, -10.2, -7.0, -4.4, 4.4, 7.2, 10.0, 12.9]: # along the back wall, clear of the path
		spots.append(Vector3(x + _rng.randf_range(-0.4, 0.4), GRAVEL_Y, -13.9))
	for side in [-1.0, 1.0]: # along the side walls
		for z in [-10.5, -6.0, -1.5, 3.0, 7.5, 11.0]:
			spots.append(Vector3(side * 13.9, GRAVEL_Y, z + _rng.randf_range(-0.6, 0.6)))
	for i in spots.size():
		_place(garden, "shrub_02", shrubs[i % shrubs.size()], spots[i], _rng.randf_range(0.75, 1.1), "Shrub%d" % i)
	var weeds := ["shrub_03_a", "shrub_03_b", "shrub_03_c", "shrub_03_d"]
	for i in 24: # weeds where the gravel meets the walls
		var side := i % 4
		var basis := Basis(Vector3.UP, side * PI / 2.0)
		var along := _rng.randf_range(-13.5, 13.5)
		if side == 2 and absf(along) < 3.2:
			along += 6.5 * signf(along + 0.01) # not on the gate path
		var at := basis * Vector3(along, 0, 14.5 - _rng.randf_range(0.0, 0.4)) + Vector3.UP * GRAVEL_Y
		_place(garden, "shrub_03", weeds[i % weeds.size()], at, _rng.randf_range(1.2, 2.0), "Weed%d" % i)


## One variant of a Poly Haven model set at `at` with a random turn and `size`.
func _place(parent: Node, source: String, variant: String, at: Vector3, size: float, node_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _prop_mesh(source, variant)
	mi.position = at
	mi.rotation.y = _rng.randf() * TAU
	mi.scale = Vector3.ONE * size
	if not source.begins_with("rock"):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF # small plants: not worth a shadow pass
	_add(parent, mi, node_name)


func _prop_mesh(source: String, variant: String) -> Mesh:
	var path := PROPS + "%s/%s.res" % [source, variant]
	if not _prop_sources.has(path):
		if not _prop_sources.has(source):
			_prop_sources[source] = (load(PROPS + "%s/%s_1k.gltf" % [source, source]) as PackedScene).instantiate()
		var node: MeshInstance3D = (_prop_sources[source] as Node).find_child(variant, true, false)
		ResourceSaver.save(node.mesh, path, ResourceSaver.FLAG_COMPRESS)
		_prop_sources[path] = load(path)
	return _prop_sources[path]


## Fallen petals: a light scatter across the paving (more toward its edges, where the wind
## leaves them) and drifts under each tree on the gravel. Drawn into textures here and laid
## over the ground as see-through quads.
func _build_fallen_petals() -> void:
	var trees: Array[Vector2] = []
	for n in stage.get_children():
		if String(n.name).begins_with("CherryTree"):
			trees.append(Vector2((n as Node3D).position.x, (n as Node3D).position.z))
	var on_paving := func(p: Vector2) -> float:
		var edge := maxf(absf(p.x), absf(p.y)) / PLATFORM
		return 0.25 + 0.75 * smoothstep(0.55, 1.0, edge)
	var on_gravel := func(p: Vector2) -> float:
		var d := 0.0
		for t in trees:
			d += exp(-p.distance_squared_to(t + Vector2(0.8, 0.4)) / 9.0)
		if maxf(absf(p.x), absf(p.y)) < PLATFORM + 0.2:
			return 0.0 # the paving has its own
		return clampf(d, 0.0, 1.0) * 0.9 + 0.04
	_petal_layer(Vector2(PLATFORM, PLATFORM), 0.004, 4500, on_paving, 2048, "PavingPetals", "res://assets/stages/temple/petals_paving.res")
	_petal_layer(Vector2(15.0, 15.0), GRAVEL_Y + 0.006, 42000, on_gravel, 2048, "GravelPetals", "res://assets/stages/temple/petals_gravel.res")


func _petal_layer(half: Vector2, y: float, count: int, density: Callable, size: int, node_name: String, path: String) -> void:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var px_per_m := size / (half.x * 2.0)
	var placed := 0
	var tries := 0
	while placed < count and tries < count * 20:
		tries += 1
		var p := Vector2(_rng.randf_range(-half.x, half.x), _rng.randf_range(-half.y, half.y))
		if _rng.randf() > density.call(p):
			continue
		placed += 1
		var cx := (p.x + half.x) * px_per_m
		var cy := (p.y + half.y) * px_per_m
		var length := _rng.randf_range(0.012, 0.02) * px_per_m
		var width := length * 0.6
		var angle := _rng.randf() * TAU
		var colour := BLOSSOM.lerp(Color(0.97, 0.78, 0.84), _rng.randf()).lerp(Color(0.62, 0.45, 0.4), 0.35 * pow(_rng.randf(), 4.0))
		var reach := int(ceil(length)) + 1
		for yy in range(int(cy) - reach, int(cy) + reach + 1):
			for xx in range(int(cx) - reach, int(cx) + reach + 1):
				if xx < 0 or yy < 0 or xx >= size or yy >= size:
					continue
				var d := Vector2(xx + 0.5 - cx, yy + 0.5 - cy).rotated(-angle)
				var e := (d.x / length) * (d.x / length) + (d.y / width) * (d.y / width)
				if e <= 1.0:
					img.set_pixel(xx, yy, Color(colour, clampf((1.0 - e) * 4.0, 0.0, 0.95)))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	ResourceSaver.save(tex, path, ResourceSaver.FLAG_COMPRESS)
	var plane := PlaneMesh.new()
	plane.size = half * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(path)
	# Cut out, not blended: a blended quad over the whole courtyard costs 1.8 ms a frame.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	mat.roughness = 0.8
	mat.texture_repeat = false
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position.y = y
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(stage, mi, node_name)
	print("fallen petals: %s %d" % [node_name, placed])


## Petals drifting down across the courtyard.
func _build_petals() -> void:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(14, 1, 14)
	process.direction = Vector3(0.4, -1, 0.2)
	process.spread = 25.0
	process.initial_velocity_min = 0.4
	process.initial_velocity_max = 0.9
	process.gravity = Vector3(0.15, -0.35, 0.05)
	process.angular_velocity_min = -180.0
	process.angular_velocity_max = 180.0
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.6
	process.turbulence_noise_scale = 3.0
	process.scale_min = 0.6
	process.scale_max = 1.2
	process.color = BLOSSOM
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://assets/stages/temple/cherry/textures/petal.png") # one sakura petal
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.4
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	quad.material = mat
	var petals := GPUParticles3D.new()
	petals.process_material = process
	petals.draw_pass_1 = quad
	petals.amount = 260
	petals.lifetime = 12.0
	petals.preprocess = 12.0
	petals.visibility_aabb = AABB(Vector3(-16, -2, -16), Vector3(32, 12, 32))
	petals.position = Vector3(0, 7.0, -2.0)
	petals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(stage, petals, "Petals")


## Three rings of mountain ridges, darker near and hazier far, fading into the sky.
func _build_mountains() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.9
	noise.fractal_octaves = 4
	var gullies := FastNoiseLite.new()
	gullies.seed = 78
	gullies.frequency = 0.05
	gullies.fractal_octaves = 5
	# Radius, peak height, and the ring's colour in the haze (darker near, paler far).
	var ridges := [[110.0, 22.0, Color(0.2, 0.12, 0.2)], [160.0, 34.0, Color(0.38, 0.22, 0.32)], [230.0, 48.0, Color(0.62, 0.38, 0.4)]]
	for r in ridges.size():
		var radius: float = ridges[r][0]
		var peak: float = ridges[r][1]
		var color: Color = ridges[r][2]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		const SEGMENTS := 320
		const ROWS := 10
		var grid := []
		for j in ROWS + 1:
			var t := float(j) / ROWS
			var row := []
			for i in SEGMENTS + 1:
				var a := TAU * i / SEGMENTS
				var top := _ridge_height(noise, a, r, peak)
				var out := Vector3(sin(a), 0, cos(a))
				# The face leans back as it rises; gullies and spurs cut into it.
				var d := radius - 28.0 * (1.0 - t) + gullies.get_noise_2d(a * radius, t * 40.0 + r * 50.0) * 9.0 * (1.0 - t * 0.5)
				var y := lerpf(-30.0, top, pow(t, 0.85))
				row.append(out * d + Vector3.UP * y)
			grid.append(row)
		for j in ROWS:
			for i in SEGMENTS:
				var p00: Vector3 = grid[j][i]
				var p10: Vector3 = grid[j][i + 1]
				var p01: Vector3 = grid[j + 1][i]
				var p11: Vector3 = grid[j + 1][i + 1]
				for v in [p00, p01, p11, p00, p11, p10]:
					st.add_vertex(v)
		st.generate_normals()
		# Unlit in the ring's haze colour with the Express's aerial rock-and-grass texture as
		# detail (mountain_haze.gdshader): a lit material over the whole horizon cost 0.6 ms a
		# frame for a difference nobody could see at this distance.
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/stages/shared/mountain_haze.gdshader")
		mat.set_shader_parameter("detail_tex", load("res://assets/stages/train/textures/aerial_grass_rock_diff_1k.jpg"))
		mat.set_shader_parameter("haze", Vector3(color.r, color.g, color.b))
		mat.set_shader_parameter("peak_height", peak)
		var mesh := st.commit()
		mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(stage, mi, "Mountains%d" % r)


func _ridge_height(noise: FastNoiseLite, angle: float, ridge: int, peak: float) -> float:
	var n := noise.get_noise_2d(cos(angle) * 3.0 + ridge * 10.0, sin(angle) * 3.0) * 0.5 + 0.5
	return peak * (0.35 + 0.65 * n * n)


# --- Helpers ---------------------------------------------------------------------

func _batch(material: Material, size: Vector3, xform: Transform3D) -> void:
	var box := BoxMesh.new()
	box.size = size
	_append(material, box, xform)


func _batch_cylinder(material: Material, top: float, bottom: float, height: float, xform: Transform3D) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = top
	cylinder.bottom_radius = bottom
	cylinder.height = height
	cylinder.radial_segments = 10
	cylinder.rings = 1
	_append(material, cylinder, xform)


func _batch_sphere(material: Material, size: float, at: Vector3) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = size
	sphere.height = size * 1.6
	sphere.radial_segments = 12
	sphere.rings = 6
	_append(material, sphere, Transform3D(Basis(), at))


## Candlelight wavering in the lit stone lanterns (FireFlicker).
func _build_lantern_flicker() -> void:
	var flicker := Node.new()
	flicker.set_script(load(FLICKER_SCRIPT))
	_add(stage, flicker, "LanternFlicker")
	var lights: Array[NodePath] = []
	for i in 4:
		lights.append(NodePath("../LanternLight%d" % i))
	flicker.set("lights", lights)
	flicker.set("amount", 0.15)


## Baked contact shadows on the gravel (StageAO) around the platform, its steps, the
## lanterns, walls and trees.
func _bake_contact_shadows() -> void:
	StageAO.collect(_footprints, stage, GRAVEL_Y, ["Geometry", "CherryTree0", "CherryTree1", "CherryTree2", "CherryTree3", "CherryTree4", "CherryTree5"])
	var half := Vector2(16.0, 16.0)
	var image := StageAO.bake(_footprints, Vector2.ZERO, half, 256)
	_add(stage, StageAO.overlay(StageAO.save(image, AO_PATH), Vector2.ZERO, half, GRAVEL_Y), "GravelShadows")
	print("baked contact shadows from %d footprints" % _footprints.size())


func _append(material: Material, mesh: PrimitiveMesh, xform: Transform3D) -> void:
	StageAO.add_aabb(_footprints, xform * mesh.get_aabb(), GRAVEL_Y)
	var st: SurfaceTool = _batches.get(material)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_batches[material] = st
	st.append_from(mesh, 0, xform)


func _flush_batches() -> void:
	var group := _add(stage, Node3D.new(), "Geometry")
	var i := 0
	for material: Material in _batches:
		var mesh := (_batches[material] as SurfaceTool).commit()
		mesh.surface_set_material(0, material)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		_add(group, mi, "Batch%d" % i)
		i += 1


func _add(parent: Node, node: Node, node_name: String) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = stage
	return node


func _add_mesh(mesh: Mesh, pos: Vector3, node_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	_add(stage, mi, node_name)


func _marker(pos: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.position = pos
	return m


func _hex(radius: float, height: float, material: Material) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 6
	mesh.material = material
	return mesh


func _cylinder(radius: float, height: float, material: Material, segments: int) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m


## Poly Haven PBR set (diff / nor_gl / rough), tinted, world-triplanar-tiled per meter.
func _textured(texture_name: String, tint: Color, tiling: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	# "dojo/white_plaster_02": another stage's texture, shared rather than copied.
	var dir := TEX if not "/" in texture_name else "res://assets/stages/%s/textures/" % texture_name.get_slice("/", 0)
	texture_name = texture_name.get_file()
	m.albedo_texture = load(dir + texture_name + "_diff_1k.jpg")
	m.normal_enabled = true
	m.normal_texture = load(dir + texture_name + "_nor_gl_1k.jpg")
	m.roughness_texture = load(dir + texture_name + "_rough_1k.jpg")
	m.uv1_scale = Vector3(tiling, tiling, tiling)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	return m


func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m
