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
