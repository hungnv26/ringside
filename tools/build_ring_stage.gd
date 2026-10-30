extends SceneTree
## Builds the boxing ring stage (res://scenes/stages/ring.tscn): ring, arena, crowd,
## lighting truss, and environment. Re-run after changing anything below.
##
## Atmosphere: a crowd of real people that cheers with the fight (Crowd.people), dust in the beams and camera flashes
## in the stands (StageFX), and baked contact shadows on the canvas and floor (StageAO).
##
## Run: godot_console --headless --path . -s res://tools/build_ring_stage.gd
##
## Layout: canvas top at y = 0 (fighters stand on it), canvas 9 m square with corner
## posts at ±4.4 m, ring platform 1 m tall, arena floor at y = -1.

const OUTPUT := "res://scenes/stages/ring.tscn"
const TEX := "res://assets/stages/ring/textures/"
const HDRI := "res://assets/stages/ring/basement_boxing_ring_1k.hdr"
const STAGE_SCRIPT := "res://scripts/stages/stage.gd"
const CROWD_SCRIPT := "res://scripts/stages/crowd.gd"
const AO_DIR := "res://assets/stages/ring/"

const CANVAS_HALF := 4.5
const POST_OFFSET := 4.4
const PLATFORM_HEIGHT := 1.0
const FLOOR_Y := -PLATFORM_HEIGHT
const ROPE_HEIGHTS := [0.45, 0.85, 1.25]
const ROPE_COLORS := [Color(0.1, 0.2, 0.75), Color(0.92, 0.92, 0.92), Color(0.75, 0.08, 0.08)]
const RED_CORNER := Color(0.75, 0.08, 0.08)
const BLUE_CORNER := Color(0.1, 0.2, 0.75)
const NEUTRAL_CORNER := Color(0.85, 0.85, 0.85)
const BRAND_NAVY := Color(0.06, 0.08, 0.2)

var stage: Node3D


func _initialize() -> void:
	stage = Node3D.new()
	stage.name = "Ring"
	stage.set_script(load(STAGE_SCRIPT))
	stage.set("dust_color", Color(0.85, 0.85, 0.86)) # canvas chalk and resin
	stage.set("edge_style", 1) # Fighter.EdgeStyle.ROPES: knocked into the ropes, fighters bounce off

	_build_environment()
	_build_lights()
	_build_ring()
	_build_arena()
	_build_ringside()
	_build_crowd()
	_build_atmosphere()
	_add(stage, StageFX.ambience([["res://assets/audio/ambience/arena_crowd.ogg", -10.0]], "res://assets/audio/ambience/crowd_cheer.ogg", -4.0), "Sound") # ambient loops (StageAmbience)
	_bake_contact_shadows()
	_add(stage, _marker(Vector3(-2, 0, 0)), "P1Spawn")
	_add(stage, _marker(Vector3(2, 0, 0)), "P2Spawn")

	var scene := PackedScene.new()
	var err := scene.pack(stage)
	if err == OK:
		err = ResourceSaver.save(scene, OUTPUT)
	print("saved ", OUTPUT, " err=", err)
	stage.free()
	quit()


# --- Environment & lighting ------------------------------------------------------

func _build_environment() -> void:
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = load(HDRI)
	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	# The HDRI was shot inside a ring, so it only lights the scene; the visible
	# background is a dark arena void.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.016, 0.025)
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.2
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.1
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.adjustment_enabled = true # a little punch for the arena lights
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.08
	# SSAO costs ~25% frame time on integrated GPUs for little visible gain here.
	env.ssao_enabled = false
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.009 # enough haze for the beams to read
	env.volumetric_fog_albedo = Color(0.9, 0.9, 1.0)
	env.volumetric_fog_length = 40.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_add(stage, world_env, "WorldEnvironment")


func _build_lights() -> void:
	var lights := _add(stage, Node3D.new(), "Lights")
	# Key light straight down over the ring, with shadows.
	var key := SpotLight3D.new()
	key.position = Vector3(0, 9, 0)
	key.rotation_degrees = Vector3(-90, 0, 0)
	key.light_energy = 14.0
	key.spot_range = 14.0
	key.spot_angle = 38.0
	key.spot_attenuation = 0.6
	key.light_color = Color(1.0, 0.97, 0.9)
	key.shadow_enabled = true
	key.light_volumetric_fog_energy = 1.5
	_add(lights, key, "KeyLight")
	# Four angled truss spots from the corners for modelling and rim light.
	var corner := 0
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			corner += 1
			var spot := SpotLight3D.new()
			var pos := Vector3(x * 6.0, 7.5, z * 6.0)
			spot.transform = Transform3D(Basis.looking_at(Vector3(0, 0.8, 0) - pos), pos)
			_add(lights, spot, "TrussSpot%d" % corner)
			spot.light_energy = 6.0
			spot.spot_range = 16.0
			spot.spot_angle = 24.0
			spot.light_color = Color(0.85, 0.9, 1.0)
			spot.light_volumetric_fog_energy = 2.0
			spot.shadow_enabled = corner == 1
	# Dim cool fill so the crowd and arena don't fall to pure black.
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 40, 0)
	fill.light_energy = 0.15
	fill.light_color = Color(0.6, 0.7, 1.0)
	_add(lights, fill, "ArenaFill")

	# Lighting truss (visual only).
	var truss_mat := _material(Color(0.12, 0.12, 0.13), 0.4, 0.8)
	var truss := _add(stage, Node3D.new(), "Truss")
	for i in 4:
		var beam := _box(Vector3(12.4, 0.3, 0.3), truss_mat)
		var along_x := i < 2
		var side := -6.2 if i % 2 == 0 else 6.2
		beam.position = Vector3(0, 7.8, side) if along_x else Vector3(side, 7.8, 0)
		if not along_x:
			beam.rotation_degrees.y = 90.0
		_add(truss, beam, "Beam%d" % i)


# --- Ring ------------------------------------------------------------------------

func _build_ring() -> void:
	var ring := _add(stage, Node3D.new(), "BoxingRing")

	var canvas_mat := _textured("terlenka", Color(0.82, 0.85, 0.9), 6.0)
	var canvas := _box(Vector3(CANVAS_HALF * 2, 0.12, CANVAS_HALF * 2), canvas_mat)
	canvas.position.y = -0.06
	_add(ring, canvas, "Canvas")
	# Wear on the canvas: scuffed where the fighters work, rubber marks, dried stains, grime
	# along the ropes (multiplied over it, like the contact shadows).
	var wear := StageAO.overlay(_canvas_wear(), Vector2.ZERO, Vector2(CANVAS_HALF, CANVAS_HALF), 0.0)
	wear.position.y = 0.001
	_add(ring, wear, "CanvasWear")
	# Sponsor prints (fictional) between the logo and the ropes.
	for i in 2:
		var print_label := _label(["IRONWOOD ATHLETICS", "HARBOUR CITY BOXING CLUB"][i], 64, Color(BRAND_NAVY, 0.7))
		print_label.position = Vector3(0, 0.004, -3.0 if i == 0 else 3.0)
		print_label.rotation_degrees.x = -90.0
		_add(ring, print_label, "CanvasPrint%d" % i)

	# Center logo: a disc and the game's name printed on the canvas.
	var disc_mat := _material(Color(BRAND_NAVY, 0.85), 0.0, 0.7)
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = 1.7
	disc_mesh.bottom_radius = 1.7
	disc_mesh.height = 0.004
	disc_mesh.radial_segments = 64
	disc_mesh.material = disc_mat
	disc.mesh = disc_mesh
	disc.position.y = 0.002
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(ring, disc, "LogoDisc")
	var logo := _label("3D FIGHTER", 150, Color(0.95, 0.75, 0.2))
	logo.position.y = 0.006
	logo.rotation_degrees.x = -90.0
	_add(ring, logo, "LogoText")

	# Apron skirt with branding on all four sides.
	var apron_mat := _textured("fabric_leather_02", BRAND_NAVY, 3.0)
	var apron := _box(Vector3(CANVAS_HALF * 2 + 0.3, PLATFORM_HEIGHT - 0.12, CANVAS_HALF * 2 + 0.3), apron_mat)
	apron.position.y = FLOOR_Y + (PLATFORM_HEIGHT - 0.12) / 2.0
	_add(ring, apron, "Apron")
	for i in 4:
		var banner := _label("3D FIGHTER", 110, Color(0.95, 0.75, 0.2))
		var angle := i * PI / 2.0
		var out := Vector3(sin(angle), 0, cos(angle))
		banner.position = out * (CANVAS_HALF + 0.16) + Vector3.UP * (FLOOR_Y + 0.5)
		banner.rotation.y = angle
		_add(ring, banner, "ApronBanner%d" % i)

	var collision := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CANVAS_HALF * 2, PLATFORM_HEIGHT, CANVAS_HALF * 2)
	shape.shape = box
	collision.position.y = FLOOR_Y / 2.0
	_add(ring, collision, "Collision")
	_add(collision, shape, "Shape")

	# Corner posts with padded turnbuckle covers.
	var post_mat := _material(Color(0.55, 0.56, 0.6), 0.9, 0.3)
	var corner_colors := {Vector2(-1, -1): RED_CORNER, Vector2(1, 1): BLUE_CORNER}
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			var corner := Node3D.new()
			corner.position = Vector3(x * POST_OFFSET, 0, z * POST_OFFSET)
			_add(ring, corner, "Corner_%s%s" % ["E" if x > 0 else "W", "S" if z > 0 else "N"])
			var post := _cylinder(0.07, 1.65, post_mat)
			post.position.y = 0.78
			_add(corner, post, "Post")
			var pad_color: Color = corner_colors.get(Vector2(x, z), NEUTRAL_CORNER)
			var pad := _box(Vector3(0.26, 1.05, 0.26), _textured("fabric_leather_02", pad_color, 1.0))
			pad.position.y = 0.85
			_add(corner, pad, "Pad")

	# Ropes: three levels, round, slightly glossy.
	var span := POST_OFFSET * 2.0
	for level in ROPE_HEIGHTS.size():
		var rope_mat := _material(ROPE_COLORS[level], 0.0, 0.35)
		for side in 4:
			var rope := _cylinder(0.028, span, rope_mat)
			var along_x := side < 2
			var offset := -POST_OFFSET if side % 2 == 0 else POST_OFFSET
			rope.position = Vector3(0, ROPE_HEIGHTS[level], offset) if along_x else Vector3(offset, ROPE_HEIGHTS[level], 0)
			rope.rotation_degrees = Vector3(0, 0, 90) if along_x else Vector3(90, 0, 0)
			_add(ring, rope, "Rope_%d_%d" % [level, side])
			rope.add_to_group(&"ring_side_%d" % side, true)

	# Steps at the red and blue corners.
	var step_mat := _material(Color(0.1, 0.1, 0.12), 0.2, 0.6)
	for corner_sign in [-1.0, 1.0]:
		for i in 3:
			var h := PLATFORM_HEIGHT * (i + 1) / 4.0
			var step := _box(Vector3(1.2, h, 0.35), step_mat)
			step.position = Vector3(corner_sign * (CANVAS_HALF + 0.35 + (2 - i) * 0.35), FLOOR_Y + h / 2.0, corner_sign * (CANVAS_HALF - 0.7))
			step.rotation_degrees.y = 90.0
			_add(ring, step, "Step_%s_%d" % ["red" if corner_sign < 0 else "blue", i])


# --- Arena -----------------------------------------------------------------------

func _build_arena() -> void:
	var arena := _add(stage, Node3D.new(), "Arena")
	var floor_mat := _textured("concrete_floor_worn_001", Color(0.35, 0.35, 0.38), 18.0)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(80, 80)
	floor_mesh.material = floor_mat
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.position.y = FLOOR_Y
	_add(arena, floor_mi, "Floor")

	# Barricade around the ringside area.
	var barrier_mat := _material(Color(0.05, 0.05, 0.06), 0.1, 0.5)
	var barrier_dist := 8.0
	for i in 4:
		var along_x := i < 2
		var side := -barrier_dist if i % 2 == 0 else barrier_dist
		var wall := _box(Vector3(barrier_dist * 2, 1.1, 0.15), barrier_mat)
		wall.position = Vector3(0, FLOOR_Y + 0.55, side) if along_x else Vector3(side, FLOOR_Y + 0.55, 0)
		if not along_x:
			wall.rotation_degrees.y = 90.0
		_add(arena, wall, "Barricade%d" % i)
		var strip := _box(Vector3(barrier_dist * 2, 0.06, 0.02), _emissive(Color(0.95, 0.6, 0.15), 2.0))
		strip.position = wall.position + Vector3.UP * 0.45 + (Vector3(0, 0, -0.085 * signf(side)) if along_x else Vector3(-0.085 * signf(side), 0, 0))
		strip.rotation_degrees = wall.rotation_degrees
		_add(arena, strip, "LedStrip%d" % i)

	# Tiered concrete stands on all four sides (the seats and the people in them are
	# Crowd's).
	var tier_mat := _textured("concrete_floor_worn_001", Color(0.32, 0.32, 0.34), 0.4)
	for side in 4:
		for row in CROWD_ROWS:
			var tier := _box(Vector3(TIER_WIDTH, TIER_RISE * (row + 1), TIER_DEPTH), tier_mat)
			var dist := TIER_START + row * TIER_DEPTH
			tier.position = _side_point(side, dist, 0.0) + Vector3.UP * (FLOOR_Y + TIER_RISE * (row + 1) / 2.0)
			tier.rotation.y = side * PI / 2.0
			_add(arena, tier, "Tier_%d_%d" % [side, row])


# --- Ringside ----------------------------------------------------------------------

const PROPS := "res://assets/stages/ring/props/"
## Officials at the judges' table (seated spectator models, see _build_crowd).
var _officials: Array[Transform3D] = []


## Poly Haven props (CC0) between the ring and the barricades: each corner's stool, spit
## bucket, water and the cutman's kit; the judges' table on the far side with its officials
## and a camcorder;
## crates, boxes, bins and extinguishers by the barricades.
func _build_ringside() -> void:
	var ringside := _add(stage, Node3D.new(), "Ringside")
	for corner_sign in [-1.0, 1.0]:
		var c: float = corner_sign
		var corner := "Red" if c < 0 else "Blue"
		_prop(ringside, "metal_stool_01", Vector3(c * 5.3, FLOOR_Y, c * 5.25), 30.0, corner + "Stool")
		_prop(ringside, "wooden_bucket_01", Vector3(c * 4.95, FLOOR_Y + 0.01, c * 5.55), 0.0, corner + "Bucket")
		_prop(ringside, "plastic_bottle_gallon", Vector3(c * 5.7, FLOOR_Y, c * 5.6), 75.0, corner + "Water")
		_prop(ringside, "medical_box", Vector3(c * 6.05, FLOOR_Y + 0.04, c * 4.95), 20.0, corner + "CutmanKit")
		_prop(ringside, "medical_tape", Vector3(c * 6.0, FLOOR_Y + 0.1, c * 4.95), 0.0, corner + "Tape")
	# Judges' table along the far (-Z) side, facing the ring: a draped press table with a
	# camcorder on it, three officials behind it.
	var drape := _textured("terlenka", BRAND_NAVY.lightened(0.08), 2.0)
	var table := _box(Vector3(5.0, 0.76, 0.8), drape)
	table.position = Vector3(0, FLOOR_Y + 0.38, -6.0)
	_add(ringside, table, "JudgesTable")
	var top := _box(Vector3(5.04, 0.02, 0.84), _textured("terlenka", Color(0.82, 0.83, 0.86), 2.0))
	top.position = Vector3(0, FLOOR_Y + 0.77, -6.0)
	_add(ringside, top, "JudgesTableTop")
	_prop(ringside, "vintage_video_camera", Vector3(2.2, FLOOR_Y + 0.78, -5.85), 180.0, "Camcorder")
	for i in 4:
		var x := -1.9 + i * 1.25
		_prop(ringside, "plastic_monobloc_chair_01", Vector3(x, FLOOR_Y, -7.0), 0.0, "JudgesChair%d" % i)
		if i < 3:
			_officials.append(Transform3D(Basis(), Vector3(x, FLOOR_Y - 0.04, -6.92)))
	# Clutter by the barricades.
	_prop(ringside, "metal_trash_can", Vector3(-7.35, FLOOR_Y + 0.07, -7.35), 15.0, "Bin0")
	_prop(ringside, "metal_trash_can", Vector3(7.35, FLOOR_Y + 0.07, -7.35), -40.0, "Bin1")
	_prop(ringside, "plastic_crate_02", Vector3(-7.4, FLOOR_Y, -3.0), 90.0, "Crate0")
	_prop(ringside, "plastic_crate_02", Vector3(-7.4, FLOOR_Y + 0.25, -3.0), 80.0, "Crate1")
	_prop(ringside, "plastic_crate_02", Vector3(-7.35, FLOOR_Y, -2.45), 95.0, "Crate2")
	_prop(ringside, "cardboard_box_01", Vector3(7.3, FLOOR_Y + 0.18, -3.4), 10.0, "Box0")
	_prop(ringside, "cardboard_box_01", Vector3(7.3, FLOOR_Y + 0.52, -3.35), 25.0, "Box1")
	_prop(ringside, "korean_fire_extinguisher_01", Vector3(7.65, FLOOR_Y, -5.6), -90.0, "Extinguisher0")
	_prop(ringside, "korean_fire_extinguisher_01", Vector3(-7.65, FLOOR_Y, 5.6), 90.0, "Extinguisher1")


func _prop(parent: Node, id: String, pos: Vector3, yaw_degrees: float, node_name: String) -> Node3D:
	var prop: Node3D = (load(PROPS + "%s/%s_1k.gltf" % [id, id]) as PackedScene).instantiate()
	prop.position = pos
	prop.rotation_degrees.y = yaw_degrees
	_add(parent, prop, node_name)
	return prop


## The canvas's wear as a multiply texture over the 9 m canvas (white = clean): broad
## scuffing where the fighters work (the middle, along X), rubber marks from shoes, a few
## dried water and sweat stains, grime along the ropes. Seeded, so rebuilds match.
func _canvas_wear() -> Texture2D:
	const SIZE := 2048
	var metres_per_px := CANVAS_HALF * 2.0 / SIZE
	var broad := FastNoiseLite.new()
	broad.seed = 11
	broad.fractal_octaves = 5
	broad.frequency = metres_per_px / 0.7 # features about 0.7 m across
	var fine := FastNoiseLite.new()
	fine.seed = 12
	fine.frequency = metres_per_px / 0.04
	var broad_img := broad.get_image(SIZE, SIZE)
	var fine_img := fine.get_image(SIZE, SIZE)
	var amount := PackedFloat32Array()
	amount.resize(SIZE * SIZE)
	for y in SIZE:
		var z := (y + 0.5) * metres_per_px - CANVAS_HALF
		for x in SIZE:
			var xm := (x + 0.5) * metres_per_px - CANVAS_HALF
			var n := broad_img.get_pixel(x, y).r
			var f := fine_img.get_pixel(x, y).r
			var r := sqrt(xm * xm + z * z)
			var work := smoothstep(4.2, 0.6, r) * (0.45 + 0.55 * exp(-pow(z / 1.6, 2.0)))
			var edge := smoothstep(0.5, 0.0, CANVAS_HALF - maxf(absf(xm), absf(z)))
			amount[y * SIZE + x] = work * 0.2 * smoothstep(0.3, 0.75, n) + edge * 0.22 * n + 0.035 * f
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	# Dried stains: a faint inside and a darker rim.
	for i in 9:
		var cx := rng.randf_range(-3.8, 3.8)
		var cz := rng.randf_range(-3.8, 3.8)
		var radius := rng.randf_range(0.12, 0.4)
		var reach := int((radius * 1.3) / metres_per_px)
		var px := int((cx + CANVAS_HALF) / metres_per_px)
		var py := int((cz + CANVAS_HALF) / metres_per_px)
		for y in range(maxi(py - reach, 0), mini(py + reach, SIZE)):
			for x in range(maxi(px - reach, 0), mini(px + reach, SIZE)):
				var d := Vector2(x - px, y - py).length() * metres_per_px
				var wobble := radius * (1.0 + 0.25 * (broad_img.get_pixel(x, y).r - 0.5))
				if d < wobble:
					var rim := smoothstep(wobble * 0.8, wobble, d)
					amount[y * SIZE + x] += 0.03 + 0.04 * rim
	# Rubber marks from shoes: short arcs, mostly in the middle.
	for i in 220:
		var p := Vector2(rng.randfn(0.0, 1.6), rng.randfn(0.0, 1.0)).clampf(-4.0, 4.0)
		var heading := rng.randf() * TAU
		var turn := rng.randf_range(-2.5, 2.5)
		var length := rng.randf_range(0.08, 0.45)
		var width := rng.randf_range(0.006, 0.02)
		var dark := rng.randf_range(0.05, 0.16)
		var steps := int(length / (metres_per_px * 0.7))
		for s in steps:
			var t := float(s) / steps
			var fade := sin(t * PI) # thin at both ends
			var w := width * fade
			var cx := int((p.x + CANVAS_HALF) / metres_per_px)
			var cy := int((p.y + CANVAS_HALF) / metres_per_px)
			var rad := maxi(int(w / metres_per_px), 1)
			for y in range(maxi(cy - rad, 0), mini(cy + rad + 1, SIZE)):
				for x in range(maxi(cx - rad, 0), mini(cx + rad + 1, SIZE)):
					var k := y * SIZE + x
					amount[k] = maxf(amount[k], dark * fade)
			heading += turn * metres_per_px * 0.7
			p += Vector2(cos(heading), sin(heading)) * metres_per_px * 0.7
	var grime := Color(0.36, 0.31, 0.27)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in SIZE:
		for x in SIZE:
			var a := clampf(amount[y * SIZE + x], 0.0, 0.6)
			img.set_pixel(x, y, Color(1.0 - a * (1.0 - grime.r), 1.0 - a * (1.0 - grime.g), 1.0 - a * (1.0 - grime.b)))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	ResourceSaver.save(tex, AO_DIR + "canvas_wear.res", ResourceSaver.FLAG_COMPRESS)
	return load(AO_DIR + "canvas_wear.res")


const CROWD_ROWS := 9
const TIER_START := 9.5
const TIER_DEPTH := 0.9
const TIER_RISE := 0.45
const TIER_WIDTH := 24.0
const SEAT_SPACING := 0.62


## Point on side `side` (0..3 around the ring) at distance `dist`, offset `along` it.
func _side_point(side: int, dist: float, along: float) -> Vector3:
	var angle := side * PI / 2.0
	var out := Vector3(sin(angle), 0, cos(angle))
	var tangent := Vector3(cos(angle), 0, -sin(angle))
	return out * dist + tangent * along


func _build_crowd() -> void:
	# Spectators are generated at runtime by crowd.gd (MultiMesh instance data isn't kept
	# when built headless); these settings must match the tiers above.
	var crowd := MultiMeshInstance3D.new()
	crowd.set_script(load(CROWD_SCRIPT))
	crowd.set("rows", CROWD_ROWS)
	crowd.set("tier_start", TIER_START)
	crowd.set("tier_depth", TIER_DEPTH)
	crowd.set("tier_rise", TIER_RISE)
	crowd.set("row_width", TIER_WIDTH)
	crowd.set("seat_spacing", SEAT_SPACING)
	crowd.set("floor_y", FLOOR_Y)
	crowd.set("people", true) # MakeHuman spectators on stadium seats (tools/mpfb/build_crowd.py)
	crowd.set("officials", _officials)
	_add(stage, crowd, "Crowd")


## Dust drifting through the spotlight beams over the ring, and camera flashes popping
## around the stands (StageFX).
func _build_atmosphere() -> void:
	var dust := StageFX.motes(Vector3(5.5, 3.0, 5.5), 260)
	dust.position = Vector3(0, 3.5, 0)
	_add(stage, dust, "Dust")
	var flashes := StageFX.flashes(TIER_START + 0.5, TIER_START + CROWD_ROWS * TIER_DEPTH, CROWD_ROWS * TIER_RISE, 8)
	flashes.position = Vector3(0, FLOOR_Y + CROWD_ROWS * TIER_RISE * 0.5 + 0.6, 0)
	_add(stage, flashes, "CameraFlashes")


## Baked contact shadows (StageAO): on the canvas around the posts, and on the arena
## floor around the ring platform, its steps, the barricades and the first tiers.
func _bake_contact_shadows() -> void:
	var on_canvas := []
	StageAO.collect(on_canvas, stage, 0.0)
	var canvas_ao := StageAO.save(StageAO.bake(on_canvas, Vector2.ZERO, Vector2(CANVAS_HALF, CANVAS_HALF), 128), AO_DIR + "canvas_ao.res")
	_add(stage, StageAO.overlay(canvas_ao, Vector2.ZERO, Vector2(CANVAS_HALF, CANVAS_HALF), 0.0), "CanvasShadows")
	var on_floor := []
	StageAO.collect(on_floor, stage, FLOOR_Y, ["Floor"])
	var floor_ao := StageAO.save(StageAO.bake(on_floor, Vector2.ZERO, Vector2(12.5, 12.5), 256), AO_DIR + "arena_ao.res")
	_add(stage, StageAO.overlay(floor_ao, Vector2.ZERO, Vector2(12.5, 12.5), FLOOR_Y), "ArenaShadows")
	print("baked contact shadows: %d on the canvas, %d on the floor" % [on_canvas.size(), on_floor.size()])


# --- Helpers ---------------------------------------------------------------------

func _add(parent: Node, node: Node, node_name: String) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = stage
	return node


func _marker(pos: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.position = pos
	return m


func _box(size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _cylinder(radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 16
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


## Poly Haven PBR set (diff / nor_gl / rough), tinted and tiled.
func _textured(texture_name: String, tint: Color, tiling: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.albedo_texture = load(TEX + texture_name + "_diff_1k.jpg")
	m.normal_enabled = true
	m.normal_texture = load(TEX + texture_name + "_nor_gl_1k.jpg")
	m.roughness_texture = load(TEX + texture_name + "_rough_1k.jpg")
	m.uv1_scale = Vector3(tiling, tiling, tiling)
	m.uv1_triplanar = true
	return m


func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


func _label(text: String, font_size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = font_size
	label.pixel_size = 0.004
	label.modulate = color
	label.outline_size = 0
	label.shaded = true
	label.double_sided = false
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return label
