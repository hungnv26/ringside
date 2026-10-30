extends SceneTree
## Stills of a stage from free cameras (not the fight camera), to check props and crowds
## up close. Uses the High graphics preset, like a match.
##
## Run WINDOWED: godot --path . -s res://tools/render_stage_views.gd -- <out_prefix> <stage> [excitement]
## Writes <out_prefix>_<view>.jpg for each view in VIEWS[stage].

const VIEWS := {
	"ring": {
		"judges": [Vector3(0, 1.6, -2.5), Vector3(0, -0.3, -7.0)],
		"red_corner": [Vector3(-2.0, 1.3, -2.0), Vector3(-5.6, -0.6, -5.4)],
		"stands": [Vector3(3.0, 1.8, -4.0), Vector3(-1.0, 0.6, -12.0)],
		"wide": [Vector3(0, 6.5, 13.0), Vector3(0, 0, -2.0)],
	},
	"dojo": {
		"kamiza": [Vector3(0, 1.8, -4.0), Vector3(0, 1.8, -10.0)],
		"taiko": [Vector3(3.0, 1.5, -6.0), Vector3(5.2, 0.9, -8.6)],
		"students": [Vector3(-2.5, 1.4, 0.5), Vector3(-7.2, 0.4, -1.0)],
		"wide": [Vector3(0, 5.5, 9.0), Vector3(0, 0.5, -3.0)],
	},
	"market": {
		"fruit": [Vector3(0.2, 1.6, -3.0), Vector3(0.2, 1.1, -7.5)],
		"locals": [Vector3(4.0, 1.7, 1.5), Vector3(9.5, 1.0, -1.0)],
		"wide": [Vector3(0, 5.0, 8.0), Vector3(0, 1.0, -5.0)],
	},
	"beach": {
		"palm": [Vector3(-4.0, 3.5, 1.0), Vector3(-8.5, 5.5, -4.5)],
		"shore": [Vector3(6.0, 1.6, -6.0), Vector3(12.0, 0.3, -12.5)],
		"umbrellas": [Vector3(-5.0, 2.0, 0.0), Vector3(-10.5, 1.5, 4.5)],
		"wide": [Vector3(0, 6.0, 10.0), Vector3(0, 1.5, -6.0)],
	},
	"courtyard": {
		"gate": [Vector3(0, 1.7, 0.0), Vector3(0, 1.4, -7.5)],
		"planters": [Vector3(4.0, 1.5, -2.5), Vector3(5.5, 0.6, -6.6)],
		"table": [Vector3(4.5, 1.6, -1.0), Vector3(6.9, 0.7, -3.6)],
		"pigeons": [Vector3(-1.5, 2.6, -5.0), Vector3(-3.0, 2.3, -7.2)],
		"wide": [Vector3(0, 4.5, 7.0), Vector3(0, 1.5, -5.0)],
	},
	"temple": {
		"tree": [Vector3(-5.5, 1.8, -1.5), Vector3(-10.5, 2.6, -7.0)],
		"gate": [Vector3(0, 2.2, 6.0), Vector3(0, 2.4, -10.5)],
		"hall": [Vector3(3.0, 2.0, -6.0), Vector3(9.0, 2.8, -19.0)],
		"pagoda": [Vector3(-2.5, 2.0, -7.0), Vector3(-7.5, 4.0, -21.0)],
		"wide": [Vector3(0, 7.5, 14.0), Vector3(0, 1.0, -6.0)],
	},
}


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var prefix: String = args[0]
	var stage_name: String = args[1]
	var excitement := float(args[2]) if args.size() > 2 else 0.0
	root.size = Vector2i(1920, 1080)
	var stage: Node3D = (load("res://scenes/stages/%s.tscn" % stage_name) as PackedScene).instantiate()
	root.add_child(stage)
	var settings := root.get_node_or_null("/root/Settings")
	if settings:
		settings.set("graphics", 2)
		settings.call("apply_graphics_to_stage", stage)
	var camera := Camera3D.new()
	camera.fov = 50.0
	stage.add_child(camera)
	camera.current = true
	for n in stage.find_children("*", "", true, false):
		if n is StageAmbience:
			n.excitement = excitement
			n.set_process(false)
	for view: String in VIEWS[stage_name]:
		var v: Array = VIEWS[stage_name][view]
		camera.look_at_from_position(v[0], v[1])
		for i in 40:
			await process_frame
		var path := "%s_%s.jpg" % [prefix, view]
		root.get_texture().get_image().save_jpg(path, 0.9)
		print("saved ", path)
	quit()
