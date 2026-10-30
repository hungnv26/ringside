extends SceneTree
## Close-ups of one fighter for the graphics work (docs/graphics-plan.md, phase 2): the
## head, the whole body in guard, and three frames from moves, under a neutral studio light,
## saved side by side as one sheet.
##
## Run WINDOWED: godot --path . -s res://tools/render_fighter_look.gd -- <id> <out.png> [model.gltf]
## The optional model replaces the character's model for this run only (no outfit, no hair
## pieces: the new MakeHuman models carry their own).

const CELL := Vector2i(640, 800)
const SHOTS := [
	{clip = &"ual1/A_TPose", time = 0.0, frame = "body"},
	{clip = &"fight/guard", time = 0.5, frame = "face"},
	{clip = &"fight/guard", time = 0.5, frame = "body"},
	{clip = &"fight/high_kick", time = 0.35, frame = "body"},
	{clip = &"fight/uppercut", time = 0.25, frame = "body"},
	{clip = &"fight/victory_flex", time = 1.2, frame = "body"},
]


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0])
	var out: String = args[1]
	var settings: Node = root.get_node("Settings")
	settings.graphics = settings.Graphics.HIGH
	settings.resolution = settings.RESOLUTIONS.size() - 1
	settings.apply_graphics(root)
	var character: CharacterData
	for c: CharacterData in root.get_node("GameState").roster:
		if c.id == id:
			character = c.duplicate() as CharacterData
	if args.size() > 2:
		character.model_scene = load(args[2])
		character.hair_scenes = []
		character.outfit_mesh = null
		character.outfit_body_mesh = null
		character.body_albedo = load(args[2].get_base_dir() + "/textures/skin.png")
		character.alt_body_albedo = null
		character.hair_color = Color(0.16, 0.13, 0.12)
		character.model_scale = 1.0
	var sheet := Image.create(CELL.x * SHOTS.size(), CELL.y, false, Image.FORMAT_RGBA8)
	for i in SHOTS.size():
		var img := await _shot(character, SHOTS[i])
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(i * CELL.x, 0))
	sheet.save_png(out)
	print("saved ", out)
	quit()


func _shot(character: CharacterData, shot: Dictionary) -> Image:
	var vp := SubViewport.new()
	vp.size = CELL
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.16, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.7)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var key := DirectionalLight3D.new()
	key.light_energy = 1.7
	key.light_color = Color(1.0, 0.95, 0.88)
	key.shadow_enabled = true
	vp.add_child(key)
	key.look_at_from_position(Vector3(1.6, 2.6, -2.2), Vector3(0, 1.2, 0))
	var rim := DirectionalLight3D.new()
	rim.light_energy = 1.8
	rim.light_color = Color(0.6, 0.72, 1.0)
	vp.add_child(rim)
	rim.look_at_from_position(Vector3(-1.6, 2.0, 2.2), Vector3(0, 1.2, 0))
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.3, 0.3, 0.32)
	floor_mesh.material_override = floor_mat
	vp.add_child(floor_mesh)

	var model := FighterModel.new()
	vp.add_child(model)
	model.build(character)
	for i in 3:
		model.show_clip(shot.clip, shot.time, 1.0, 1.0 / 60.0)
		await process_frame
	var camera := Camera3D.new()
	vp.add_child(camera)
	camera.current = true
	if shot.frame == "face":
		var head := model.skeleton.global_transform * model.skeleton.get_bone_global_pose(model.skeleton.find_bone("Head")).origin
		camera.fov = 22.0
		camera.look_at_from_position(head + Vector3(0.45, 0.05, -1.05), head + Vector3(0, 0.06, 0))
		model._blink_in = INF
		for i in 3:
			model.set_gaze(camera.global_position, 1.0)
			await process_frame
	else:
		camera.fov = 34.0
		camera.look_at_from_position(Vector3(1.6, 1.25, -3.2), Vector3(0, 0.95, 0))
	for i in 3:
		await process_frame
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	vp.queue_free()
	await process_frame
	return img
