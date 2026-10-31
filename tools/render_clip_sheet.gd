extends SceneTree
## A contact sheet of one clip on one fighter, side on under a studio light, for the
## movement work (docs/movement-plan.md). The motion layer runs (floor lift, transitions);
## its footwork is off, so this is the clip as authored.
##
## Run WINDOWED: godot --path . -s res://tools/render_clip_sheet.gd -- <fighter> <library/clip> <out.png> [frames=8] [start=0] [end=clip length]

const CELL := Vector2i(360, 440)


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0])
	var clip := StringName(args[1])
	var out: String = args[2]
	var frames := int(args[3]) if args.size() > 3 else 8
	var character: CharacterData
	for c: CharacterData in root.get_node("GameState").roster:
		if c.id == id:
			character = c
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
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var key := DirectionalLight3D.new()
	key.light_energy = 1.7
	key.shadow_enabled = true
	vp.add_child(key)
	key.look_at_from_position(Vector3(2.0, 2.6, 1.0), Vector3(0, 1.0, 0))
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
	model.rotation.y = PI * 0.5 # faces +X: the camera sees the side, opponent to the right
	var camera := Camera3D.new()
	vp.add_child(camera)
	camera.current = true
	camera.fov = 42.0
	camera.look_at_from_position(Vector3(0.2, 1.0, 3.6), Vector3(0.2, 0.75, 0))
	var length := model.clip_length(clip)
	var start := float(args[4]) if args.size() > 4 else 0.0
	var finish := float(args[5]) if args.size() > 5 else length
	var columns := mini(frames, 8)
	var rows := ceili(float(frames) / columns)
	var sheet := Image.create(CELL.x * columns, CELL.y * rows, false, Image.FORMAT_RGBA8)
	for i in frames:
		var t := lerpf(start, finish, float(i) / maxf(frames - 1, 1))
		for k in 3:
			model.show_clip(clip, t, 1.0, 1.0 / 60.0)
			await process_frame
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i((i % columns) * CELL.x, (i / columns) * CELL.y))
	sheet.save_png(out)
	print("saved ", out)
	quit()
