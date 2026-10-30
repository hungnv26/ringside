extends SceneTree
## Checks the crowd's vertex-animation textures (tools/mpfb/build_crowd.py): spectator
## variants in a row, each in one clip (idle, talk, cheer, clap), seated on a bench.
##
## Run WINDOWED: godot --path . -s res://tools/render_crowd_check.gd -- <out.png> [id ...]

const SIZE := Vector2i(1600, 700)


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var out: String = args[0]
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/crowd/crowd.json"))
	var ids: Array = args.slice(1) if args.size() > 1 else meta.keys()
	var vp := SubViewport.new()
	vp.size = SIZE
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
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 1.6
	key.shadow_enabled = true
	vp.add_child(key)
	key.look_at_from_position(Vector3(2, 4, 4), Vector3.ZERO)
	var clips := ["idle", "talk", "cheer", "clap"]
	var x := 0.0
	for id: String in ids:
		var info: Dictionary = meta[id]
		var mesh := _mesh(id)
		var material := ShaderMaterial.new()
		material.shader = load("res://assets/crowd/crowd_vat.gdshader")
		material.set_shader_parameter("vat_pos", load("res://assets/crowd/%s_pos.res" % id))
		material.set_shader_parameter("vat_nrm", load("res://assets/crowd/%s_nrm.res" % id))
		material.set_shader_parameter("albedo_tex", load("res://assets/crowd/%s_atlas.png" % id))
		material.set_shader_parameter("fps", float(info.fps))
		for clip in clips:
			material.set_shader_parameter("clip_" + clip, Vector2(info.clips[clip][0], info.clips[clip][1]))
		material.set_shader_parameter("excitement", 0.5)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = clips.size()
		for i in clips.size():
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x + i * 0.9, 0, 0)))
			mm.set_instance_color(i, Color.WHITE)
			# talk: b = 1; cheer: g = 0 (always excited enough); clap: g = 0 and a = 1.
			var custom: Color = [Color(0.1, 2.0, 0.0, 0.0), Color(0.2, 2.0, 1.0, 0.0), Color(0.3, 0.0, 0.0, 0.0), Color(0.4, 0.0, 0.0, 1.0)][i]
			mm.set_instance_custom_data(i, custom)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = material
		vp.add_child(mmi)
		var bench := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(clips.size() * 0.9, 0.45, 0.5)
		bench.mesh = box
		bench.position = Vector3(x + (clips.size() - 1) * 0.45, 0.225, 0.1)
		vp.add_child(bench)
		x += clips.size() * 0.9 + 0.6
	var camera := Camera3D.new()
	vp.add_child(camera)
	camera.current = true
	camera.fov = 40.0
	camera.look_at_from_position(Vector3(x / 2.0 - 0.3, 1.4, x * 0.55 + 1.5), Vector3(x / 2.0 - 0.3, 0.7, 0))
	await create_timer(1.3).timeout
	vp.get_texture().get_image().save_png(out)
	print("saved ", out)
	quit()


func _mesh(id: String) -> Mesh:
	var scene: Node = (load("res://assets/crowd/%s.glb" % id) as PackedScene).instantiate()
	var mi := scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mesh := mi.mesh
	scene.free()
	return mesh
