extends SceneTree
## Turns the crowd's raw vertex-animation data (tools/mpfb/build_crowd.py writes
## assets/crowd/<id>_pos.vat and <id>_nrm.vat: little-endian RGBA half floats, row 0 first,
## one row per frame, one column per vertex) into <id>_pos.res / <id>_nrm.res textures, and
## the same for each spectator's level of detail (<id>_lod_*).
## Godot's EXR reader garbles Blender's half-float EXRs, so the data skips EXR altogether.
##
## godot --headless --path . -s res://tools/crowd_vat_import.gd [-- id ...]

const DIR := "res://assets/crowd/"


func _initialize() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "crowd.json"))
	var ids: Array = OS.get_cmdline_user_args()
	if ids.is_empty():
		ids = meta.keys()
	var failures := 0
	var stems := []
	for id: String in ids:
		stems.append([id, int(meta[id].vertices), int(meta[id].rows)])
		if meta[id].has("lod"): # the back rows' level of detail, same clips
			stems.append([id + "_lod", int(meta[id].lod.vertices), int(meta[id].rows)])
	for stem: Array in stems:
		var id: String = stem[0]
		for suffix in ["pos", "nrm"]:
			var bytes := FileAccess.get_file_as_bytes(DIR + "%s_%s.vat" % [id, suffix])
			var width: int = stem[1]
			var rows: int = stem[2]
			if bytes.size() != width * rows * 8:
				printerr("%s_%s.vat: %d bytes, expected %d" % [id, suffix, bytes.size(), width * rows * 8])
				failures += 1
				continue
			var img := Image.create_from_data(width, rows, false, Image.FORMAT_RGBAH, bytes)
			var tex := ImageTexture.create_from_image(img)
			var path := DIR + "%s_%s.res" % [id, suffix]
			if ResourceSaver.save(tex, path, ResourceSaver.FLAG_COMPRESS) != OK:
				printerr("could not save ", path)
				failures += 1
			else:
				print("VAT ", path, " ", width, "x", rows)
	quit(1 if failures else 0)
