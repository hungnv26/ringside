extends SceneTree
## Checks the coach overlay's panels (Phase 5): corner talk, plan chips, the read badge
## and the round card, in a CPU-vs-CPU coached match with no link (sample text).
##
## Run WINDOWED: godot --path . -s res://tools/render_coach_overlay_check.gd -- <out.jpg>


func _initialize() -> void:
	await process_frame
	var out: String = OS.get_cmdline_user_args()[0]
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
	gs.player_character = gs.roster[0]
	gs.p2_character = gs.roster[2]
	gs.stage_path = "res://scenes/stages/dojo.tscn"
	gs.match_seed = 9
	change_scene_to_file("res://scenes/fight.tscn")
	for i in 4:
		await process_frame
	var m = current_scene
	m.start_fight_immediately()
	await create_timer(2.0).timeout
	var link = m.coach_link
	print("link: ", link != null)
	if link:
		link._show_talk(0, "They keep jumping in. Anti-air is up, and I'll punish the landing.")
		var c0: Array[String] = ["block ↑ 0.85", "range → mid", "uppercut ↑ 2"]
		link._show_chips(0, c0)
		link._show_badge(0, "CALLED IT · jump")
		link._show_talk(1, "Pressure works. Stay close and mix throws in.")
		var c1: Array[String] = ["aggression ↑ 0.8", "throw ↑ 1.6"]
		link._show_chips(1, c1)
		var summary: Dictionary = link.round_summary()
		link._show_card(m.fighters[0], "K.O.", summary)
	await create_timer(0.5).timeout
	var img := root.get_texture().get_image()
	img.resize(1920, 1080, Image.INTERPOLATE_LANCZOS)
	img.save_jpg(out, 0.9)
	print("saved ", out)
	quit()
