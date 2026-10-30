extends SceneTree
## Checks the Phase 4 fight effects in a real CPU-vs-CPU fight (docs/graphics-plan.md):
## saves frames of a heavy hit's sparks and impact burst, an impact frame with its
## shockwave, a super's darkened background, knockdown dust and debris, footprints on the
## beach, and the K.O. replay.
##
## Run WINDOWED: godot --path . -s res://tools/render_fx_check.gd -- <out_dir> [stage]

const SIZE := Vector2i(1920, 1080)


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var out: String = args[0]
	var stage_name: String = args[1] if args.size() > 1 else "beach"
	DirAccess.make_dir_recursive_absolute(out)
	var settings: Node = root.get_node("Settings")
	var gs: Node = root.get_node("GameState")
	settings.graphics = 2
	settings.fight_intros = false
	gs._apply_coach_window("1080p", self)
	for i in 10:
		await process_frame
	settings.apply_graphics(root)
	gs.mode = gs.Mode.COACH
	gs.coach_url = ""
	gs.player_character = _character(gs, &"jin")
	gs.p2_character = _character(gs, &"rhea")
	gs.stage_path = "res://scenes/stages/%s.tscn" % stage_name
	gs.match_seed = 77
	change_scene_to_file("res://scenes/fight.tscn")
	for i in 4:
		await process_frame
	var m = current_scene
	m.start_fight_immediately()
	m.hud.visible = true
	await create_timer(3.0).timeout
	var a: Node3D = m.fighters[0]
	var b: Node3D = m.fighters[1]
	var mid := (a.global_position + b.global_position) * 0.5 + Vector3.UP * 1.2
	# A heavy hit: sparks and the impact burst.
	m.fx.spark(mid, Color(1.0, 0.75, 0.35), 1.8) # FightFx.HIT_COLOR (the tool loads before the autoloads)
	m.fx.smoke(mid, Color(0.85, 0.83, 0.8), 1.2)
	await create_timer(0.06).timeout
	_save(out, "1_heavy_hit")
	# An impact frame and its shockwave.
	m.fx.screen.impact_frame(Color(1.0, 0.92, 0.85))
	m.fx.screen._impact = 0.3 # held longer than in play (two frames), to be caught on camera
	await process_frame
	await process_frame
	_save(out, "2_impact_frame")
	await create_timer(0.35).timeout
	m.fx.screen.shockwave(mid, 1.0)
	await create_timer(0.12).timeout
	_save(out, "3_shockwave")
	# A super's freeze darkens all but the fighter.
	m.fx.screen.darken_on(a, 0.8)
	await create_timer(0.35).timeout
	_save(out, "4_super_darken")
	await create_timer(0.8).timeout
	# Knockdown dust and debris where the second fighter stands.
	var floor_point: Vector3 = Vector3(b.global_position.x, 0.0, b.global_position.z)
	m.fx.dust(floor_point)
	m.fx.smoke(floor_point + Vector3.UP * 0.15, m.fx._dust_color(), 1.3)
	m.fx._debris(floor_point + Vector3.UP * 0.05)
	await create_timer(0.25).timeout
	_save(out, "5_knockdown_dust")
	await create_timer(3.0).timeout
	_save(out, "6_footprints")
	# A K.O.: drop the second fighter's health and let the fight finish it.
	b.health = 1
	var t := 0.0
	while not m.ko_replay.playing() and t < 30.0:
		await create_timer(0.1).timeout
		t += 0.1
	print("FX replay started after %.1f s, shown %d" % [t, m.ko_replay.shown])
	await create_timer(1.6).timeout
	_save(out, "7_ko_replay")
	while m.ko_replay.playing():
		await process_frame
	await create_timer(0.3).timeout
	_save(out, "8_after_replay")
	print("FX impact frames %d, phase %s" % [m.fx.screen.impact_frames, m.Phase.keys()[m.phase]])
	quit()


func _save(out: String, name: String) -> void:
	var img := root.get_texture().get_image()
	img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	img.save_jpg("%s/%s.jpg" % [out, name], 0.88)
	print("saved ", name)


func _character(gs: Node, id: StringName) -> Resource:
	for c in gs.roster:
		if c.id == id:
			return c
	return gs.roster[0]
