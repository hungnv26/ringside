extends SceneTree
## The graphics work's measuring stick (docs/graphics-plan.md): stills of every stage from
## the fight camera, and frame times per stage, both in a coached match's window (1080p in
## screen points: 3200×1800 pixels on a 16" MacBook Pro).
##
## Run WINDOWED (needs a renderer):
##   godot --path . -s res://tools/look_capture.gd -- stills docs/look/before [preset] [stage ...]
##   godot --path . -s res://tools/look_capture.gd -- bench [preset] [seconds] [stage ...]
## preset: low, medium, high (default) or showcase. Stills are the neutral view and one
## moment 6 s into a CPU-vs-CPU fight, saved as <stage>.jpg and <stage>_fight.jpg at
## 1920×1080. bench prints one BENCH line per stage: average fps, GPU and CPU frame ms.

const STILL_SIZE := Vector2i(1920, 1080)
const P1 := &"jin"
const P2 := &"mira"
const SEED := 20261030


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var what := args[0] if args.size() > 0 else "stills"
	var settings: Node = root.get_node("Settings")
	var gs: Node = root.get_node("GameState")
	var rest: Array = Array(args.slice(1))
	var out := "docs/look/before"
	if what == "stills" and not rest.is_empty():
		out = rest.pop_front()
	var preset := "high"
	if not rest.is_empty() and rest[0] in ["low", "medium", "high", "showcase"]:
		preset = rest.pop_front()
	var seconds := 10.0
	if what == "bench" and not rest.is_empty() and String(rest[0]).is_valid_float():
		seconds = float(rest.pop_front())
	var only: Array = rest
	settings.graphics = ["low", "medium", "high", "showcase"].find(preset)
	settings.fight_intros = false # not saved
	gs._apply_coach_window("1080p", self) # sets the 3D scale for the preset, as a coached match does
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for i in 10:
		await process_frame
	settings.apply_graphics(root)
	var rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	print("LOOK %s preset=%s window=%s" % [what, preset, DisplayServer.window_get_size()])
	if what == "stills":
		DirAccess.make_dir_recursive_absolute(out)
	for stage: Dictionary in gs.STAGES:
		var name := String(stage.path).get_file().get_basename()
		if not only.is_empty() and not name in only:
			continue
		gs.mode = gs.Mode.COACH # both fighters are Hard CPUs; no link, no demo banner
		gs.coach_url = ""
		gs.player_character = _character(gs, P1)
		gs.p2_character = _character(gs, P2)
		gs.stage_path = stage.path
		gs.match_seed = SEED
		change_scene_to_file("res://scenes/fight.tscn")
		for i in 4:
			await process_frame
		var manager = current_scene
		manager.hud.visible = what == "bench"
		manager.start_fight_immediately()
		_experiment(manager.stage)
		if what == "stills":
			manager.set_physics_process(false)
			for i in 40: # stances, reflection probes and the camera settle
				await process_frame
			_save(out, name)
			manager.set_physics_process(true)
			await create_timer(6.0).timeout
			_save(out, name + "_fight")
		else:
			await create_timer(2.0).timeout # shaders, probes
			var frames := 0
			var gpu := 0.0
			var cpu := 0.0
			var start := Time.get_ticks_usec()
			var drawn := Engine.get_frames_drawn()
			while Time.get_ticks_usec() - start < seconds * 1e6:
				await process_frame
				frames += 1
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
				cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
			var fps := (Engine.get_frames_drawn() - drawn) / ((Time.get_ticks_usec() - start) / 1e6)
			print("BENCH %-10s fps=%6.1f gpu_ms=%5.2f cpu_ms=%5.2f" % [name, fps, gpu / frames, cpu / frames])
	quit()


## LOOK_* environment variables switch single effects on over the preset, to price them:
## LOOK_SSAO, LOOK_SSIL, LOOK_SSR, LOOK_SDFGI, LOOK_VOXELGI (baked at load), LOOK_TAA,
## LOOK_FSR=<scale> (FSR 2 upscaling at that 3D scale), LOOK_SCALE=<scale> (bilinear).
func _experiment(stage: Node) -> void:
	var on := func(name: String) -> bool: return OS.get_environment(name) == "1"
	var env: Environment
	for node in stage.find_children("*", "WorldEnvironment", true, false):
		env = (node as WorldEnvironment).environment
	if env:
		if on.call("LOOK_SSAO"): env.ssao_enabled = true
		if on.call("LOOK_SSIL"): env.ssil_enabled = true
		if on.call("LOOK_SSR"): env.ssr_enabled = true
		if on.call("LOOK_SDFGI"): env.sdfgi_enabled = true
	if on.call("LOOK_VOXELGI"):
		var gi := VoxelGI.new()
		gi.size = Vector3(24, 10, 24)
		gi.position = Vector3(0, 4, 0)
		stage.add_child(gi)
		var t := Time.get_ticks_msec()
		gi.bake(stage)
		print("LOOK voxelgi baked in %d ms" % (Time.get_ticks_msec() - t))
	if on.call("LOOK_TAA"): root.use_taa = true
	if OS.get_environment("LOOK_FSR") != "":
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
		root.scaling_3d_scale = float(OS.get_environment("LOOK_FSR"))
	if OS.get_environment("LOOK_METALFX") != "": # spatial or temporal
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL if OS.get_environment("LOOK_METALFX") == "temporal" else Viewport.SCALING_3D_MODE_METALFX_SPATIAL
		print("LOOK scaling mode ", root.scaling_3d_mode)
	if OS.get_environment("LOOK_SCALE") != "":
		root.scaling_3d_scale = float(OS.get_environment("LOOK_SCALE"))


func _character(gs: Node, id: StringName) -> CharacterData:
	for c: CharacterData in gs.roster:
		if c.id == id:
			return c
	return gs.roster[0]


func _save(out: String, name: String) -> void:
	var image := root.get_texture().get_image()
	image.resize(STILL_SIZE.x, STILL_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s.jpg" % [out, name]
	image.save_jpg(path, 0.9)
	print("saved ", path)
