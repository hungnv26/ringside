extends SceneTree
## Checks the Phase 5 HUD and presentation in a real match: the intro's stage shot and a
## fighter's shot, then the fight HUD (portraits, bars, pips, timer, meters), fresh damage
## (the white chip before the red trail), a combo counter with its damage, and a low bar.
##
## Run WINDOWED: godot --path . -s res://tools/render_hud_check.gd -- <out_dir> [stage]

const SIZE := Vector2i(1920, 1080)


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var out: String = args[0]
	var stage_name: String = args[1] if args.size() > 1 else "temple"
	DirAccess.make_dir_recursive_absolute(out)
	var settings: Node = root.get_node("Settings")
	var gs: Node = root.get_node("GameState")
	settings.graphics = 2
	settings.fight_intros = true
	gs._apply_coach_window("1080p", self)
	for i in 10:
		await process_frame
	settings.apply_graphics(root)
	gs.mode = gs.Mode.VS_CPU
	gs.player_character = _character(gs, &"lian")
	gs.p2_character = _character(gs, &"kenji")
	gs.stage_path = "res://scenes/stages/%s.tscn" % stage_name
	gs.match_seed = 5
	change_scene_to_file("res://scenes/fight.tscn")
	await create_timer(1.4).timeout
	_save(out, "1_intro_stage")
	await create_timer(2.6).timeout
	_save(out, "2_intro_fighter")
	var m = current_scene
	if m.intro:
		m.intro.skip()
	await create_timer(5.0).timeout
	_save(out, "3_fight_hud")
	var p2: Node = m.fighters[1]
	var p1: Node = m.fighters[0]
	p2._take_damage(180)
	p2._set_combo(2)
	p2._take_damage(60)
	p2._set_combo(3)
	await create_timer(0.06).timeout
	_save(out, "4_fresh_damage_combo")
	p1._take_damage(int(p1.health * 0.8))
	await create_timer(1.2).timeout
	_save(out, "5_low_health")
	quit()


func _save(out: String, name: String) -> void:
	var img := root.get_texture().get_image()
	img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	img.save_jpg("%s/%s.jpg" % [out, name], 0.9)
	print("saved ", name)


func _character(gs: Node, id: StringName) -> Resource:
	for c in gs.roster:
		if c.id == id:
			return c
	return gs.roster[0]
