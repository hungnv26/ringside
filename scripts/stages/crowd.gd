class_name Crowd
extends MultiMeshInstance3D
## Spectators on tiered seating around the ring (or kneeling students along a dojo's walls),
## generated at runtime (a MultiMesh built in a headless tool doesn't keep its instance data).
##
## With `people`, real people: the twelve MakeHuman spectators from tools/mpfb/build_crowd.py
## on modelled stadium seats, animated by vertex-animation textures (crowd_vat.gdshader). Each
## sits still or chats while the arena is calm and cheers or claps once the stage's crowd
## excitement (StageAmbience) passes their own threshold. Without it, one merged torso + head
## mesh, instanced per seat with a random shirt color, or a color from `palette`.

@export var rows := 9
## Distance from the ring center to the first row, and per-row depth/rise.
@export var tier_start := 9.5
@export var tier_depth := 0.9
@export var tier_rise := 0.45
@export var row_width := 24.0
@export var seat_spacing := 0.62
@export var floor_y := -1.0
@export_range(0.0, 1.0) var empty_seat_chance := 0.18
@export var crowd_seed := 1984
## Which sides to fill (0 = +Z, 1 = +X, 2 = -Z, 3 = -X).
@export var sides := PackedInt32Array([0, 1, 2, 3])
## If set, clothing colors are picked from here (with slight variation).
@export var palette := PackedColorArray()
## Kneeling (seiza) students in gi and hakama instead of seated spectators. The figure
## carries its own colors; the instance color only varies it slightly.
@export var kneeling := false
## Life in the seats (assets/stages/shared/crowd.gdshader): metres each figure sways, and
## how far cheering spectators spring up now and then (0 = they stay seated).
@export var sway := 0.0
@export var jump := 0.0
## Real people on stadium seats (see above); `sway`, `jump`, `palette` and `kneeling` are
## for the simple figures only.
@export var people := false
@export var seat_color := Color(0.36, 0.05, 0.06)
## Seats between two aisles (0 = no aisles).
@export var aisle_every := 12
## Which of the people (crowd.json "kind"): "spectator" (seated, on stadium seats) or
## "student" (kneeling in seiza on the floor, no seats).
@export var people_kind := "spectator"
## Extra seated people with `people` (ringside officials): where each one's feet are,
## facing +Z. They sit still or chat and never cheer; their chairs are the stage's.
@export var officials: Array[Transform3D] = []

const CROWD_SHADER := "res://assets/stages/shared/crowd.gdshader"
const PEOPLE_DIR := "res://assets/crowd/"
const PEOPLE_SHADER := "res://assets/crowd/crowd_vat.gdshader"
## The same animation under the engine's lighting (a few people on a stage whose light
## changes; CourtyardLife's neighbours).
const PEOPLE_LIT_SHADER := "res://assets/crowd/crowd_vat_lit.gdshader"
## Share of the spectators who chat rather than sit still, and who clap rather than cheer.
const TALKERS := 0.35
const CLAPPERS := 0.45
## How fast (per second) the drawn excitement follows the stage's, so a sudden bump turns
## into people getting up over half a second rather than in one frame.
const EXCITEMENT_RATE := 2.0
## The people's own lighting (crowd_vat.gdshader): sky and floor ambient, and the ring's
## spill. The fill comes from the stage's DirectionalLight3D, if it has one.
@export var people_sky_light := Color(1.15, 1.08, 1.06)
@export var people_ground_light := Color(0.36, 0.34, 0.34)
@export var people_ring_light := Color(0.0, 0.0, 0.0)

## Rows drawn with the full mesh; the rows behind them use the lighter level of detail.
const NEAR_ROWS := 1
## How much darker each row is than the one in front of it.
const BACK_ROW_DIMMING := 0.035

var _people_materials: Array[ShaderMaterial] = []
var _ambience: Node
var _excitement := 0.0


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = crowd_seed
	if people:
		_build_people(rng)
		return
	if sway > 0.0 or jump > 0.0:
		var animated := ShaderMaterial.new()
		animated.shader = load(CROWD_SHADER)
		animated.set_shader_parameter("sway", sway)
		animated.set_shader_parameter("jump", jump)
		material_override = animated
	else:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
		mat.roughness = 0.9
		material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var seats: Array[Transform3D] = []
	var colors: Array[Color] = []
	var seats_per_row := int(row_width / seat_spacing) - 2
	for side in sides:
		var angle := side * PI / 2.0
		var out := Vector3(sin(angle), 0, cos(angle))
		var tangent := Vector3(cos(angle), 0, -sin(angle))
		for row in rows:
			for seat in seats_per_row:
				if rng.randf() < empty_seat_chance:
					continue
				var along := (seat - seats_per_row / 2.0) * seat_spacing + rng.randf_range(-0.08, 0.08)
				var dist := tier_start + row * tier_depth + rng.randf_range(-0.1, 0.1)
				var pos := out * dist + tangent * along + Vector3.UP * (floor_y + tier_rise * (row + 1))
				# Face the ring, with a little variety.
				var facing := Basis(Vector3.UP, angle + PI + rng.randf_range(-0.3, 0.3))
				seats.append(Transform3D(facing.scaled(Vector3.ONE * rng.randf_range(0.9, 1.1)), pos))
				if palette.is_empty():
					colors.append(Color.from_hsv(rng.randf(), rng.randf_range(0.3, 0.8), rng.randf_range(0.08, 0.3)))
				else:
					colors.append(palette[rng.randi() % palette.size()].darkened(rng.randf_range(0.0, 0.15)))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _kneeling_mesh() if kneeling else _spectator_mesh()
	mm.instance_count = seats.size()
	for i in seats.size():
		mm.set_instance_transform(i, seats[i])
		mm.set_instance_color(i, colors[i])
	multimesh = mm


func _process(delta: float) -> void:
	if _people_materials.is_empty():
		return
	if _ambience == null:
		_ambience = _find_ambience()
	var target: float = _ambience.excitement if _ambience else 0.0
	_excitement = move_toward(_excitement, target, EXCITEMENT_RATE * delta)
	for m in _people_materials:
		m.set_shader_parameter("excitement", _excitement)


## The stage's StageAmbience (its crowd excitement), if it has one.
func _find_ambience() -> Node:
	for n in get_parent().get_children():
		if n is StageAmbience:
			return n
	return null


## Seats (one MultiMesh) and the people in them (a MultiMesh per spectator model, colourway
## and side, so the stands behind the camera are culled as a whole).
func _build_people(rng: RandomNumberGenerator) -> void:
	set_process(true)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PEOPLE_DIR + "crowd.json"))
	var ids: Array = meta.keys().filter(func(k: String) -> bool: return meta[k].get("kind", "spectator") == people_kind)
	ids.sort()
	var seated := people_kind == "spectator"
	var seats: Array[Transform3D] = []
	var seat_colors: Array[Color] = []
	var placed := {} # "id/colourway/side/detail" -> [[Transform3D, Color custom, Color tint], ...]
	var seats_per_row := int(row_width / seat_spacing) - 2
	for side in sides:
		var angle := side * PI / 2.0
		var out := Vector3(sin(angle), 0, cos(angle))
		var tangent := Vector3(cos(angle), 0, -sin(angle))
		var facing := Basis(Vector3.UP, angle + PI) # the models face +Z; turn them to the ring
		for row in rows:
			for seat in seats_per_row:
				if aisle_every > 0 and seat % (aisle_every + 1) == aisle_every:
					continue
				var along := (seat - seats_per_row / 2.0) * seat_spacing
				var pos := out * (tier_start + row * tier_depth) + tangent * along + Vector3.UP * (floor_y + tier_rise * (row + 1))
				if seated:
					seats.append(Transform3D(facing, pos))
					seat_colors.append(seat_color.darkened(rng.randf_range(0.0, 0.12)))
				if rng.randf() < empty_seat_chance:
					continue
				var id: String = ids[rng.randi() % ids.size()]
				if not seated:
					pos += tangent * rng.randf_range(-0.08, 0.08) + out * rng.randf_range(-0.06, 0.06) # kneeling where they like
				var turn := Basis(Vector3.UP, angle + PI + rng.randf_range(-0.12, 0.12))
				var xform := Transform3D(turn.scaled(Vector3.ONE * rng.randf_range(0.96, 1.04)), pos)
				var custom := Color(rng.randf(), rng.randf_range(0.12, 0.85), 1.0 if rng.randf() < TALKERS else 0.0, 1.0 if rng.randf() < CLAPPERS else 0.0)
				# Rows further back sit a little further from the ring lights.
				var tint := Color.WHITE.darkened(rng.randf_range(0.0, 0.08) + row * BACK_ROW_DIMMING)
				var key := "%s/%d/%d/%s" % [id, rng.randi() % 2, side, "full" if row < NEAR_ROWS else "lod"]
				if not placed.has(key):
					placed[key] = []
				placed[key].append([xform, custom, tint])

	for xform in officials:
		var id: String = ids[rng.randi() % ids.size()]
		var key := "%s/%d/officials/full" % [id, rng.randi() % 2]
		if not placed.has(key):
			placed[key] = []
		placed[key].append([xform, _official_custom(rng), Color.WHITE])

	if seated:
		_add_seats(seats, seat_colors)
	_add_people(placed, meta)
	_people_materials.assign(_materials.values())
	_light_people()


func _add_seats(seats: Array[Transform3D], seat_colors: Array[Color]) -> void:
	var seat_mm := MultiMesh.new()
	seat_mm.transform_format = MultiMesh.TRANSFORM_3D
	seat_mm.use_colors = true
	seat_mm.mesh = _seat_mesh()
	seat_mm.instance_count = seats.size()
	for i in seats.size():
		seat_mm.set_instance_transform(i, seats[i])
		seat_mm.set_instance_color(i, seat_colors[i])
	var seat_mi := MultiMeshInstance3D.new()
	seat_mi.name = "Seats"
	seat_mi.multimesh = seat_mm
	var seat_mat := StandardMaterial3D.new()
	seat_mat.vertex_color_use_as_albedo = true
	seat_mat.vertex_color_is_srgb = true
	seat_mat.roughness = 0.45 # moulded plastic
	seat_mi.material_override = seat_mat
	seat_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(seat_mi)


var _materials := {}


func _add_people(placed: Dictionary, meta: Dictionary) -> void:
	var materials := _materials
	for key: String in placed:
		var id := key.get_slice("/", 0)
		var stem := id if key.get_slice("/", 3) == "full" or not meta[id].has("lod") else id + "_lod"
		var look := "%s/%s" % [stem, key.get_slice("/", 1)]
		if not materials.has(look):
			materials[look] = _person_material(id, stem, meta[id], key.get_slice("/", 1) == "1")
		var list: Array = placed[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _person_mesh(stem)
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i][0])
			mm.set_instance_custom_data(i, list[i][1])
			mm.set_instance_color(i, list[i][2])
		var mi := MultiMeshInstance3D.new()
		mi.name = "People_" + key.replace("/", "_")
		mi.multimesh = mm
		mi.material_override = materials[look]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 0.6 # cheering arms reach past the rest pose's bounds
		add_child(mi)


## Passes the stage's lighting to the people's shader.
func _light_people() -> void:
	var fill: DirectionalLight3D = null
	for n in get_parent().find_children("*", "DirectionalLight3D", true, false):
		fill = n
		break
	for m in _people_materials:
		m.set_shader_parameter("sky_light", Vector3(people_sky_light.r, people_sky_light.g, people_sky_light.b))
		m.set_shader_parameter("ground_light", Vector3(people_ground_light.r, people_ground_light.g, people_ground_light.b))
		m.set_shader_parameter("ring_light", Vector3(people_ring_light.r, people_ring_light.g, people_ring_light.b))
		if fill:
			var c := fill.light_color.srgb_to_linear() * fill.light_energy
			m.set_shader_parameter("fill_light", Vector3(c.r, c.g, c.b))
			m.set_shader_parameter("fill_dir", fill.global_transform.basis.z.normalized())


## `stem`: the spectator `id` or its level of detail (id_lod), which has its own mesh and
## VAT; the atlas is shared. `alt`: the second colourway of the clothes
## (tools/mpfb/build_crowd.py bake_atlas).
## An official's per-instance data for crowd_vat.gdshader: a random phase, a cheering
## threshold the excitement (0-1) never reaches, sitting still or chatting, never clapping.
func _official_custom(rng: RandomNumberGenerator) -> Color:
	return Color(rng.randf(), 2.0, 1.0 if rng.randf() < 0.5 else 0.0, 0.0)


static func _person_material(id: String, stem: String, info: Dictionary, alt: bool, lit := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(PEOPLE_LIT_SHADER if lit else PEOPLE_SHADER)
	m.set_shader_parameter("vat_pos", load(PEOPLE_DIR + stem + "_pos.res"))
	m.set_shader_parameter("vat_nrm", load(PEOPLE_DIR + stem + "_nrm.res"))
	m.set_shader_parameter("albedo_tex", load(PEOPLE_DIR + id + ("_atlas_alt.png" if alt else "_atlas.png")))
	m.set_shader_parameter("fps", float(info.fps))
	for clip: String in info.clips:
		m.set_shader_parameter("clip_" + clip, Vector2(info.clips[clip][0], info.clips[clip][1]))
	return m


static func _person_mesh(id: String) -> Mesh:
	var scene: Node = (load(PEOPLE_DIR + id + ".glb") as PackedScene).instantiate()
	var mesh := (scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh
	scene.free()
	return mesh


## A moulded stadium seat facing +Z, for a seated spectator standing at the origin (their
## seat is 0.5 m up, between 0.42 and 0.03 m behind their feet): seat pan with a rounded
## front lip, a backrest leaning back, on a steel stem and foot plate. The plastic takes the
## instance colour; the steel is dark grey.
func _seat_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var white := Color.WHITE
	var steel := Color(0.16, 0.16, 0.17)
	var pan := BoxMesh.new()
	pan.size = Vector3(0.44, 0.04, 0.36)
	_append_colored(st, pan, Transform3D(Basis(), Vector3(0, 0.48, -0.23)), white)
	var lip := CylinderMesh.new()
	lip.top_radius = 0.025
	lip.bottom_radius = 0.025
	lip.height = 0.44
	lip.radial_segments = 8
	lip.rings = 1
	_append_colored(st, lip, Transform3D(Basis(Vector3.FORWARD, PI / 2.0), Vector3(0, 0.475, -0.05)), white)
	var back := BoxMesh.new()
	back.size = Vector3(0.44, 0.42, 0.035)
	_append_colored(st, back, Transform3D(Basis(Vector3.RIGHT, -0.14), Vector3(0, 0.72, -0.44)), white)
	var stem := BoxMesh.new()
	stem.size = Vector3(0.05, 0.46, 0.05)
	_append_colored(st, stem, Transform3D(Basis(), Vector3(0, 0.23, -0.3)), steel)
	var plate := BoxMesh.new()
	plate.size = Vector3(0.2, 0.015, 0.14)
	_append_colored(st, plate, Transform3D(Basis(), Vector3(0, 0.0075, -0.3)), steel)
	st.generate_normals()
	return st.commit()


## Seiza figure facing +Z: folded legs in a dark hakama, white gi torso with a black
## belt, skin-toned head with dark hair. Colors are baked into the vertices.
func _kneeling_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hakama := Color(0.1, 0.11, 0.2)
	var gi := Color(0.93, 0.92, 0.89)
	var legs := CapsuleMesh.new()
	legs.radius = 0.19
	legs.height = 0.62
	_append_colored(st, legs, Transform3D(Basis(Vector3.RIGHT, PI / 2.0).scaled(Vector3(1.25, 1.0, 1.0)), Vector3(0, 0.17, -0.05)), hakama)
	var hips := SphereMesh.new()
	hips.radius = 0.2
	hips.height = 0.36
	_append_colored(st, hips, Transform3D(Basis().scaled(Vector3(1.15, 1.0, 1.0)), Vector3(0, 0.3, -0.12)), hakama)
	var torso := CapsuleMesh.new()
	torso.radius = 0.17
	torso.height = 0.56
	_append_colored(st, torso, Transform3D(Basis().scaled(Vector3(1.1, 1.0, 0.85)), Vector3(0, 0.6, -0.1)), gi)
	var belt := CylinderMesh.new()
	belt.top_radius = 0.19
	belt.bottom_radius = 0.19
	belt.height = 0.05
	_append_colored(st, belt, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.82)), Vector3(0, 0.44, -0.1)), Color(0.03, 0.03, 0.03))
	var head := SphereMesh.new()
	head.radius = 0.105
	head.height = 0.23
	_append_colored(st, head, Transform3D(Basis(), Vector3(0, 0.98, -0.08)), Color(0.82, 0.62, 0.48))
	var hair := SphereMesh.new()
	hair.radius = 0.11
	hair.height = 0.2
	_append_colored(st, hair, Transform3D(Basis(), Vector3(0, 1.02, -0.11)), Color(0.06, 0.05, 0.04))
	return st.commit()


func _append_colored(st: SurfaceTool, mesh: PrimitiveMesh, xform: Transform3D, color: Color) -> void:
	var arrays := mesh.get_mesh_arrays()
	var count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var colors := PackedColorArray()
	colors.resize(count)
	colors.fill(color)
	arrays[Mesh.ARRAY_COLOR] = colors
	var colored := ArrayMesh.new()
	colored.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	st.append_from(colored, 0, xform)


func _spectator_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var torso := CapsuleMesh.new()
	torso.radius = 0.2
	torso.height = 0.75
	torso.radial_segments = 8
	torso.rings = 2
	var head := SphereMesh.new()
	head.radius = 0.11
	head.height = 0.22
	head.radial_segments = 8
	head.rings = 4
	st.append_from(torso, 0, Transform3D(Basis(), Vector3(0, 0.375, 0)))
	st.append_from(head, 0, Transform3D(Basis(), Vector3(0, 0.86, 0)))
	return st.commit()
