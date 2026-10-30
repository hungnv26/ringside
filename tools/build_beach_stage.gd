extends SceneTree
## Builds the beach stage (res://scenes/stages/beach.tscn): a tropical beach at midday.
## A sand arena marked by a ring of tiki torches, turquoise sea (custom shader) rolling
## onto the shore behind the fight, leaning palm trees, a thatched tiki bar, a lifeguard
## tower, beach umbrellas and surfboards, rocks, and a beach crowd on the sand.
## Re-run after changing anything below.
##
## Run: godot_console --headless --path . -s res://tools/build_beach_stage.gd
##
## Layout: sand top at y = 0; the waterline is at z = -12.5 (sea toward -Z, behind the
## fight). Everything tall is more than 8 m out, so nothing needs hiding. Repeated
## geometry is merged into one mesh per material.

const OUTPUT := "res://scenes/stages/beach.tscn"
const TEX := "res://assets/stages/beach/textures/"
const SKY := "res://assets/stages/beach/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
const OCEAN_SHADER := "res://assets/stages/beach/ocean.gdshader"
const STAGE_SCRIPT := "res://scripts/stages/stage.gd"
const CROWD_SCRIPT := "res://scripts/stages/crowd.gd"
const AO_PATH := "res://assets/stages/beach/sand_ao.res"
const ART := "res://assets/stages/beach/art/" # tools/make_beach_art.py
const PROPS := "res://assets/stages/beach/props/"

const SHORE_Z := -12.5
## Direction toward the sun once the sky is turned 180° (sun high behind the camera, a
## little to the left), measured from the HDRI: 48° elevation.
const SUN_DIR := Vector3(-0.376, 0.743, 0.553)

var stage: Node3D
var _batches := {}
var _footprints := [] # everything standing on the sand (contact shadows)
var _rng := RandomNumberGenerator.new()
var mat_sand: StandardMaterial3D
var mat_wet_sand: StandardMaterial3D
var mat_bark: StandardMaterial3D
var mat_leaf: StandardMaterial3D
var mat_bamboo: StandardMaterial3D
var mat_thatch: StandardMaterial3D
var mat_white_wood: StandardMaterial3D
var mat_red: StandardMaterial3D
var mat_rock: StandardMaterial3D
var mat_coconut: StandardMaterial3D
var mat_flame: StandardMaterial3D
var mat_dark: StandardMaterial3D
var mat_rope: StandardMaterial3D
var _fabric := []


func _initialize() -> void:
	_rng.seed = 808
	stage = Node3D.new()
	stage.name = "Beach"
	stage.set_script(load(STAGE_SCRIPT))
	stage.set("footprints", true) # soft sand
	stage.set("dust_color", Color(0.86, 0.74, 0.55))
	stage.set("rope_line", 50.0)
	stage.set("music", &"beach")

	_make_materials()
	_build_environment()
	_build_lights()
	_build_ground()
	_build_sea()
	_build_torches()
	_build_palms()
	_build_tiki_bar(Vector3(10.5, 0, -6.5))
	_build_lifeguard_tower(Vector3(-11.0, 0, -8.5))
	_build_umbrellas()
	_build_rocks()
	_build_crowd()
	_build_spray()
	_add(stage, StageFX.ambience([["res://assets/audio/ambience/waves.ogg", -9.0], ["res://assets/audio/ambience/wind.ogg", -25.0]], "res://assets/audio/ambience/crowd_cheer.ogg", -8.0, ["res://assets/audio/ambience/seagull_1.ogg", "res://assets/audio/ambience/seagull_2.ogg"], -15.0), "Sound") # ambient loops (StageAmbience)
	_flush_batches()
	_flush_fronds()
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


func _make_materials() -> void:
	mat_sand = _textured("coast_sand_01", Color(1.18, 1.05, 0.86), 0.35)
	mat_wet_sand = _textured("coast_sand_01", Color(0.78, 0.66, 0.52), 0.35)
	mat_wet_sand.roughness = 0.35
	mat_bark = _textured("palm_tree_bark", Color(0.85, 0.75, 0.62), 1.0)
	mat_leaf = _material(Color(0.24, 0.55, 0.16), 0.0, 0.6)
	mat_leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_bamboo = _textured("bamboo_wall", Color(1.0, 0.92, 0.75), 1.0)
	mat_thatch = _textured("thatch_roof_angled", Color(1.0, 0.9, 0.7), 0.7)
	mat_white_wood = _material(Color(0.93, 0.93, 0.9), 0.0, 0.7)
	mat_red = _material(Color(0.85, 0.15, 0.12), 0.0, 0.6)
	mat_rock = _material(Color(0.42, 0.4, 0.38), 0.0, 0.85)
	mat_coconut = _material(Color(0.32, 0.2, 0.1), 0.0, 0.7)
	mat_flame = _emissive(Color(1.0, 0.6, 0.2), 4.0)
	mat_dark = _material(Color(0.12, 0.09, 0.07), 0.0, 0.8)
	mat_rope = _material(Color(0.75, 0.62, 0.42), 0.0, 0.9)
	for c in [Color(0.92, 0.2, 0.2), Color(0.98, 0.78, 0.15), Color(0.1, 0.6, 0.78), Color(0.95, 0.45, 0.65), Color(0.2, 0.72, 0.45), Color(0.98, 0.98, 0.95)]:
		_fabric.append(_material(c, 0.0, 0.8))


# --- Environment & lighting ------------------------------------------------------

func _build_environment() -> void:
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = load(SKY)
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.sky_rotation = Vector3(0, PI, 0) # sun behind the camera, the sea toward the clouds
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.95
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.18
	env.adjustment_contrast = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.ssao_enabled = false # too costly on integrated GPUs (see the stage notes)
	env.fog_enabled = true # light haze toward the horizon
	env.fog_light_color = Color(0.75, 0.85, 0.95)
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_add(stage, world_env, "WorldEnvironment")


func _build_lights() -> void:
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis.looking_at(-SUN_DIR), Vector3.ZERO)
	sun.light_energy = 2.0
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	_add(stage, sun, "Sun")
	var bounce := DirectionalLight3D.new() # warm light bounced off the sand
	bounce.rotation_degrees = Vector3(35, 20, 0)
	bounce.light_energy = 0.25
	bounce.light_color = Color(1.0, 0.85, 0.65)
	_add(stage, bounce, "SandBounce")


# --- Ground and sea ------------------------------------------------------------------

func _build_ground() -> void:
	# Dry sand, then a darker wet strip sloping gently into the water.
	# Dry sand (z -9 .. 40), level wet sand to the waterline, then a slope under the sea:
	# all tops meet at y = 0, so there's no ledge.
	_batch(mat_sand, Vector3(80, 0.4, 49), Transform3D(Basis(), Vector3(0, -0.2, 15.5)))
	_batch(mat_wet_sand, Vector3(80, 0.4, 3.5), Transform3D(Basis(), Vector3(0, -0.2, -10.75)))
	# Negative angle: the far (-z) end goes down, under the sea.
	var slope := Basis(Vector3.RIGHT, deg_to_rad(-6.0))
	_batch(mat_wet_sand, Vector3(80, 0.4, 12.0), Transform3D(slope, Vector3(0, -0.2 - sin(deg_to_rad(6.0)) * 6.0, SHORE_Z - 6.0 * cos(deg_to_rad(6.0)) + 0.05)))
	# A ring raked into the sand marks the fighting area.
	var segments := 64
	for i in segments:
		var a := TAU * i / segments
		var p := Vector3(cos(a), 0.004, sin(a)) * 4.4
		_batch(mat_wet_sand, Vector3(TAU * 4.4 / segments + 0.03, 0.01, 0.12), Transform3D(Basis(Vector3.UP, -a + PI / 2.0), p))


func _build_sea() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(900, 450)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	var material := ShaderMaterial.new()
	material.shader = load(OCEAN_SHADER)
	material.set_shader_parameter("shore_z", SHORE_Z)
	plane.material = material
	var sea := MeshInstance3D.new()
	sea.mesh = plane
	sea.position = Vector3(0, -0.06, SHORE_Z - 225.0 + 0.6)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(stage, sea, "Sea")


# --- Props -----------------------------------------------------------------------------

## Tiki torches around the back and sides of the arena (none in front of the camera).
func _build_torches() -> void:
	var count := 7
	for i in count:
		var a := deg_to_rad(205.0 + i * (130.0 / (count - 1))) # arc behind the fight
		var p := Vector3(cos(a) * 7.5, 0, sin(a) * 7.5)
		_batch(mat_bamboo, Vector3(0.09, 1.9, 0.09), Transform3D(Basis(), p + Vector3(0, 0.95, 0)))
		_batch(mat_dark, Vector3(0.18, 0.22, 0.18), Transform3D(Basis(), p + Vector3(0, 1.98, 0)))
		var flame := CylinderMesh.new()
		flame.top_radius = 0.0
		flame.bottom_radius = 0.1
		flame.height = 0.32
		flame.radial_segments = 8
		flame.material = mat_flame
		var mi := MeshInstance3D.new()
		mi.mesh = flame
		mi.position = p + Vector3(0, 2.24, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.scale = Vector3.ONE * 0.6 # the glowing core; live flames and embers around it
		_add(stage, mi, "TorchFlame%d" % i)
		var fire := StageFX.flame(0.22, 20)
		fire.position = p + Vector3(0, 2.14, 0)
		_add(stage, fire, "TorchFire%d" % i)
		var sparks := StageFX.embers(Vector3(0.05, 0.05, 0.05), 6, 1.6)
		sparks.position = p + Vector3(0, 2.3, 0)
		_add(stage, sparks, "TorchEmbers%d" % i)


## Leaning palm trees: a curved, ringed trunk, a crown of arching fronds, coconuts.
func _build_palms() -> void:
	var spots := [Vector3(-8.5, 0, -4.5), Vector3(-13.0, 0, -1.0), Vector3(8.8, 0, -2.5), Vector3(14.0, 0, 2.0),
		Vector3(-6.0, 0, -10.0), Vector3(6.5, 0, -10.5), Vector3(-16.0, 0, -7.0), Vector3(17.0, 0, -5.0)]
	for spot: Vector3 in spots:
		var lean_dir := Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-0.6, 1.0)).normalized()
		var height := _rng.randf_range(5.5, 7.5)
		var lean := _rng.randf_range(1.2, 2.6)
		var prev := spot
		var segments := 12
		for s in range(1, segments + 1):
			var t := float(s) / segments
			var p := spot + Vector3.UP * height * t + lean_dir * lean * t * t
			var dir := (p - prev).normalized()
			var basis := Basis(Vector3.UP.cross(dir).normalized(), Vector3.UP.angle_to(dir)) if dir.cross(Vector3.UP).length() > 0.001 else Basis()
			var radius := lerpf(0.26, 0.16, t)
			_batch_cylinder(mat_bark, radius * 0.92, radius, prev.distance_to(p) + 0.04, Transform3D(basis, (prev + p) / 2.0))
			prev = p
		var top := prev
		for c in 4:
			var a := TAU * c / 4.0 + 0.4
			_batch_sphere(mat_coconut, 0.14, top + Vector3(cos(a) * 0.22, -0.25, sin(a) * 0.22))
		var fronds := 9
		for f in fronds:
			var a := TAU * f / fronds + _rng.randf_range(-0.2, 0.2)
			_frond(top, Vector3(cos(a), 0, sin(a)), _rng.randf_range(2.4, 3.2))


## One frond: a strip that arcs up and droops, folded into a shallow V along its midrib,
## textured with the drawn frond (tools/make_beach_art.py). Collected into one mesh that
## sways in the wind (foliage_wind.gdshader; the vertex alpha is how far along the frond).
func _frond(base: Vector3, dir: Vector3, length: float) -> void:
	if _fronds == null:
		_fronds = SurfaceTool.new()
		_fronds.begin(Mesh.PRIMITIVE_TRIANGLES)
	const STEPS := 10
	var side := dir.cross(Vector3.UP).normalized()
	var droop := _rng.randf_range(1.6, 2.4)
	var bright := _rng.randf_range(0.8, 1.05)
	var twist := _rng.randf_range(-0.25, 0.25)
	var rows := []
	for s in STEPS + 1:
		var t := float(s) / STEPS
		var p := base + dir * length * t + Vector3.UP * (0.9 * t - droop * t * t)
		var width := 1.05 * sin(PI * (0.08 + 0.84 * t)) + 0.08
		var across := side.rotated(dir, twist * t)
		var fold := Vector3.UP * width * 0.16
		rows.append([p - across * width * 0.5, p + fold, p + across * width * 0.5, t])
	for s in STEPS:
		var a: Array = rows[s]
		var b: Array = rows[s + 1]
		for half in 2:
			var quad := [[a[half], half * 0.5, a[3]], [a[half + 1], half * 0.5 + 0.5, a[3]], [b[half + 1], half * 0.5 + 0.5, b[3]], [b[half], half * 0.5, b[3]]]
			for k in [0, 1, 2, 0, 2, 3]:
				var v: Array = quad[k]
				_fronds.set_color(Color(bright, bright, bright, v[2]))
				_fronds.set_uv(Vector2(v[1], 1.0 - v[2]))
				_fronds.add_vertex(v[0])


var _fronds: SurfaceTool


func _flush_fronds() -> void:
	_fronds.generate_normals()
	var wind := ShaderMaterial.new()
	wind.shader = load("res://assets/stages/shared/foliage_wind.gdshader")
	wind.set_shader_parameter("albedo_tex", load(ART + "frond.png"))
	wind.set_shader_parameter("sway", 0.14)
	wind.set_shader_parameter("gust_speed", 1.2)
	wind.set_shader_parameter("backlight", Color(0.3, 0.45, 0.15))
	wind.set_shader_parameter("alpha_cut", 0.4)
	_fronds.set_material(wind)
	var mi := MeshInstance3D.new()
	mi.mesh = _fronds.commit()
	_add(stage, mi, "PalmFronds")


## A thatched tiki bar: bamboo counter, posts, stools and a thatch roof.
func _build_tiki_bar(at: Vector3) -> void:
	_batch(mat_bamboo, Vector3(3.6, 1.1, 0.7), Transform3D(Basis(), at + Vector3(0, 0.55, 1.2)))
	_batch(mat_dark, Vector3(3.8, 0.08, 0.9), Transform3D(Basis(), at + Vector3(0, 1.14, 1.2)))
	for x in [-1.8, 1.8]:
		for z in [-1.4, 1.4]:
			_batch(mat_bamboo, Vector3(0.14, 2.7, 0.14), Transform3D(Basis(), at + Vector3(x, 1.35, z)))
	var roof := CylinderMesh.new()
	roof.top_radius = 0.05
	roof.bottom_radius = 3.1
	roof.height = 1.5
	roof.radial_segments = 4
	roof.material = mat_thatch
	var roof_mi := MeshInstance3D.new()
	roof_mi.mesh = roof
	roof_mi.position = at + Vector3(0, 3.4, 0)
	roof_mi.rotation.y = PI / 4.0
	_add(stage, roof_mi, "TikiRoof")
	for i in 3:
		var stool := at + Vector3(-1.2 + i * 1.2, 0, 2.1)
		_batch(mat_bamboo, Vector3(0.08, 0.75, 0.08), Transform3D(Basis(), stool + Vector3(0, 0.37, 0)))
		_batch_cylinder(mat_dark, 0.22, 0.22, 0.06, Transform3D(Basis(), stool + Vector3(0, 0.77, 0)))
	_batch(mat_white_wood, Vector3(1.6, 0.5, 0.05), Transform3D(Basis(), at + Vector3(0, 2.45, 1.45))) # sign


## Lifeguard tower: white stilts, a platform with a striped cabin, ladder and red flag.
func _build_lifeguard_tower(at: Vector3) -> void:
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			_batch(mat_white_wood, Vector3(0.14, 2.4, 0.14), Transform3D(Basis(), at + Vector3(x, 1.2, z)))
	_batch(mat_white_wood, Vector3(2.6, 0.12, 2.6), Transform3D(Basis(), at + Vector3(0, 2.45, 0)))
	_batch(mat_white_wood, Vector3(1.9, 1.6, 1.9), Transform3D(Basis(), at + Vector3(0, 3.3, 0)))
	for y in [2.75, 3.25, 3.75]:
		_batch(mat_red, Vector3(1.94, 0.16, 1.94), Transform3D(Basis(), at + Vector3(0, y, 0)))
	_batch(mat_red, Vector3(2.4, 0.12, 2.4), Transform3D(Basis(), at + Vector3(0, 4.15, 0)))
	var ramp := Basis(Vector3.RIGHT, deg_to_rad(-35.0))
	_batch(mat_white_wood, Vector3(0.7, 0.06, 3.0), Transform3D(ramp, at + Vector3(0, 1.2, 2.3)))
	_batch(mat_white_wood, Vector3(0.05, 1.5, 0.05), Transform3D(Basis(), at + Vector3(1.1, 4.9, -1.1)))
	_batch(mat_red, Vector3(0.6, 0.4, 0.02), Transform3D(Basis(), at + Vector3(1.4, 5.4, -1.1)))


## Striped umbrellas with towels beneath, and surfboards stuck upright in the sand.
func _build_umbrellas() -> void:
	var spots := [Vector3(-9.5, 0, 3.5), Vector3(-12.5, 0, 6.0), Vector3(9.5, 0, 4.5), Vector3(12.0, 0, 7.5), Vector3(-4.5, 0, -11.0), Vector3(3.0, 0, -11.5)]
	for i in spots.size():
		var at: Vector3 = spots[i]
		var tilt := Basis(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized(), _rng.randf_range(0.05, 0.18))
		_batch(mat_white_wood, Vector3(0.05, 2.2, 0.05), Transform3D(tilt, at + tilt * Vector3(0, 1.1, 0)))
		var mi := MeshInstance3D.new()
		mi.mesh = _umbrella_canopy((_fabric[i % _fabric.size()] as BaseMaterial3D).albedo_color)
		mi.transform = Transform3D(tilt, at + tilt * Vector3(0, 1.98, 0))
		_add(stage, mi, "Umbrella%d" % i)
		_batch(_fabric[(i + 2) % _fabric.size()], Vector3(0.8, 0.02, 1.7), Transform3D(Basis(Vector3.UP, _rng.randf() * PI), at + Vector3(0.6, 0.01, 0.4)))
	for i in 4:
		var at := Vector3(-7.5 + i * 0.7, 0, 7.5) if i < 2 else Vector3(10.5 + (i - 2) * 0.7, 0, -1.5)
		var board := Basis(Vector3.UP, _rng.randf_range(-0.3, 0.3)) * Basis(Vector3.RIGHT, _rng.randf_range(-0.1, 0.1))
		var mi := MeshInstance3D.new()
		mi.mesh = _surfboard((_fabric[(i + 1) % _fabric.size()] as BaseMaterial3D).albedo_color)
		mi.transform = Transform3D(board, at + Vector3(0, 0.0, 0))
		_add(stage, mi, "Surfboard%d" % i)


## A surfboard standing on its tail along Y (2.1 m): a pointed nose, a rounded tail, wide
## in the middle, thicker along the centre than at the rails, a white stringer stripe.
func _surfboard(colour: Color) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const ALONG := 24
	const ACROSS := 8
	var length := 2.1
	var grid := [[], []] # deck, bottom
	for j in ALONG + 1:
		var t := float(j) / ALONG
		var half := 0.27 * pow(sin(PI * clampf(t * 0.94 + 0.04, 0.0, 1.0)), 0.75) * (1.0 - 0.35 * t * t)
		var thick := 0.035 * pow(sin(PI * clampf(t, 0.02, 0.98)), 0.5)
		for face in 2:
			var row := []
			for i in ACROSS + 1:
				var u := float(i) / ACROSS * 2.0 - 1.0
				var z := thick * sqrt(maxf(0.0, 1.0 - u * u)) * (1.0 if face == 0 else -0.8)
				row.append(Vector3(u * half, t * length, z))
			grid[face].append(row)
	for face in 2:
		for j in ALONG:
			for i in ACROSS:
				var stripe := absf(float(i) + 0.5 - ACROSS / 2.0) < 0.6 and face == 0
				var c := Color(0.97, 0.96, 0.92) if stripe else colour
				var q := [grid[face][j][i], grid[face][j][i + 1], grid[face][j + 1][i + 1], grid[face][j + 1][i]]
				var order := [0, 2, 1, 0, 3, 2] if face == 0 else [0, 1, 2, 0, 2, 3]
				for k in order:
					st.set_color(c)
					st.add_vertex(q[k])
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.25 # glassed fibreglass
	st.set_material(mat)
	return st.commit()


## A beach umbrella's canopy: eight panels alternating `colour` and white, domed, the rim
## scalloped between the ribs; thin ribs underneath and a finial on top.
func _umbrella_canopy(colour: Color) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const PANELS := 8
	const RINGS := 5
	const ACROSS := 4
	var radius := 1.3
	var height := 0.5
	for panel in PANELS:
		var c := colour if panel % 2 == 0 else Color(0.96, 0.95, 0.92)
		for ring in RINGS:
			for k in ACROSS:
				var corners := []
				for q in [[ring, k], [ring + 1, k], [ring + 1, k + 1], [ring, k + 1]]:
					var r: float = radius * q[0] / RINGS
					var u: float = float(q[1]) / ACROSS
					var a: float = TAU * (panel + u) / PANELS
					var scallop := 0.06 * sin(PI * u) * pow(r / radius, 4.0) # the rim rises between ribs
					var y := height * (1.0 - pow(r / radius, 1.6)) + scallop
					var rr := r * (1.0 - 0.04 * sin(PI * u)) # and pulls in a little
					corners.append(Vector3(cos(a) * rr, y, sin(a) * rr))
				for v in [0, 2, 1, 0, 3, 2]:
					st.set_color(c)
					st.add_vertex(corners[v])
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.85
	mat.albedo_texture = (_fabric[0] as BaseMaterial3D).albedo_texture # the weave, if the fabric has one
	st.set_material(mat)
	var mesh := st.commit()
	# Ribs and the finial share the canopy's node as a second surface.
	var ribs := SurfaceTool.new()
	ribs.begin(Mesh.PRIMITIVE_TRIANGLES)
	for panel in PANELS:
		var a := TAU * panel / PANELS
		var rib := BoxMesh.new()
		rib.size = Vector3(0.018, 0.018, radius)
		var mid := Vector3(cos(a), 0, sin(a)) * radius * 0.5 + Vector3.UP * (height * 0.55 - 0.02)
		var basis := Basis.looking_at(Vector3(cos(a), -height / radius * 0.9, sin(a)))
		ribs.append_from(rib, 0, Transform3D(basis, mid))
	var finial := SphereMesh.new()
	finial.radius = 0.04
	finial.height = 0.08
	ribs.append_from(finial, 0, Transform3D(Basis(), Vector3.UP * (height + 0.04)))
	ribs.generate_normals()
	ribs.set_material(mat_white_wood)
	return ribs.commit(mesh)


## Rocks along the shore: Poly Haven's Rock 07 and Rock 09 (CC0), sized and half sunk in
## the sand; a few shells on the wet sand.
func _build_rocks() -> void:
	var sources := [_prop_mesh("rock_07"), _prop_mesh("rock_09")]
	for i in 12:
		var side := -1.0 if i % 2 == 0 else 1.0
		var at := Vector3(side * _rng.randf_range(9.0, 22.0), 0.0, SHORE_Z + _rng.randf_range(-2.0, 2.5))
		var mesh: Mesh = sources[i % 2]
		var extent := mesh.get_aabb().size
		var size := _rng.randf_range(0.8, 2.4) / maxf(extent.x, extent.z)
		var rock := MeshInstance3D.new()
		rock.mesh = mesh
		rock.position = at - Vector3.UP * extent.y * size * _rng.randf_range(0.15, 0.35)
		rock.rotation.y = _rng.randf() * TAU
		rock.scale = Vector3.ONE * size
		_add(stage, rock, "Rock%d" % i)
	for i in 4:
		var shell := MeshInstance3D.new()
		shell.mesh = _prop_mesh("lambis_shell")
		shell.position = Vector3(_rng.randf_range(-6.0, 6.0), 0.0, SHORE_Z + _rng.randf_range(1.0, 3.0))
		shell.rotation = Vector3(0, _rng.randf() * TAU, _rng.randf_range(-0.3, 0.3))
		_add(stage, shell, "Shell%d" % i)


var _prop_meshes := {}


## A Poly Haven model's mesh, saved on its own.
func _prop_mesh(source: String) -> Mesh:
	var path := PROPS + "%s/%s.res" % [source, source]
	if not _prop_meshes.has(path):
		var scene: Node = (load(PROPS + "%s/%s_1k.gltf" % [source, source]) as PackedScene).instantiate()
		var node := scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		ResourceSaver.save(node.mesh, path, ResourceSaver.FLAG_COMPRESS)
		scene.free()
		_prop_meshes[path] = load(path)
	return _prop_meshes[path]


## Beachgoers standing on the sand along both sides (Crowd.people).
func _build_crowd() -> void:
	var crowd := MultiMeshInstance3D.new()
	crowd.set_script(load(CROWD_SCRIPT))
	crowd.set("rows", 3)
	crowd.set("tier_start", 8.6)
	crowd.set("tier_depth", 0.85)
	crowd.set("tier_rise", 0.0)
	crowd.set("row_width", 13.0)
	crowd.set("seat_spacing", 0.9)
	crowd.set("floor_y", 0.0)
	crowd.set("empty_seat_chance", 0.4)
	crowd.set("crowd_seed", 1401)
	crowd.set("sides", PackedInt32Array([1, 3]))
	# Beachgoers standing on the sand (MakeHuman locals, tools/mpfb/build_crowd.py): they
	# cheer and clap with the fight.
	crowd.set("people", true)
	crowd.set("people_kind", "pedestrian")
	crowd.set("aisle_every", 0)
	crowd.set("people_sky_light", Color(0.75, 0.78, 0.85)) # bright midday sky
	crowd.set("people_ground_light", Color(0.55, 0.45, 0.32)) # light off the sand
	_add(stage, crowd, "Crowd")


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


func _batch_sphere(material: Material, radius: float, at: Vector3) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 10
	sphere.rings = 6
	_append(material, sphere, Transform3D(Basis(), at))


## Spray: mist drifting off the surf along the shoreline.
func _build_spray() -> void:
	var spray := StageFX.spray(Vector3(16.0, 0.3, 0.8), 36)
	spray.position = Vector3(0, 0.25, SHORE_Z - 1.5)
	_add(stage, spray, "SeaSpray")


## Baked contact shadows on the sand (StageAO) under the torches, bar, tower, umbrellas,
## rocks and palms.
func _bake_contact_shadows() -> void:
	StageAO.collect(_footprints, stage, 0.0, ["Geometry", "Sea"])
	var half := Vector2(18.0, 13.0)
	var center := Vector2(0.0, -2.0)
	var image := StageAO.bake(_footprints, center, half, 256)
	_add(stage, StageAO.overlay(StageAO.save(image, AO_PATH), center, half, 0.0), "SandShadows")
	print("baked contact shadows from %d footprints" % _footprints.size())


func _append(material: Material, mesh: PrimitiveMesh, xform: Transform3D) -> void:
	StageAO.add_aabb(_footprints, xform * mesh.get_aabb(), 0.0)
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


func _marker(pos: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.position = pos
	return m


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m


func _textured(texture_name: String, tint: Color, tiling: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.albedo_texture = load(TEX + texture_name + "_diff_1k.jpg")
	m.normal_enabled = true
	m.normal_texture = load(TEX + texture_name + "_nor_gl_1k.jpg")
	m.roughness_texture = load(TEX + texture_name + "_rough_1k.jpg")
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
