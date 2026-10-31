extends Node
## Global game state: roster, current selections, match settings.

const CHARACTER_DIR := "res://data/characters/"
const DEFAULT_STAGE := "res://scenes/stages/ring.tscn"
const DOJO_STAGE := "res://scenes/stages/dojo.tscn"
const ROOFTOP_STAGE := "res://scenes/stages/rooftop.tscn"
const TEMPLE_STAGE := "res://scenes/stages/temple.tscn"
const BEACH_STAGE := "res://scenes/stages/beach.tscn"
const MARKET_STAGE := "res://scenes/stages/market.tscn"
const TRAIN_STAGE := "res://scenes/stages/train.tscn"
const COURTYARD_STAGE := "res://scenes/stages/courtyard.tscn"
## Selectable stages: scene, display name, select-screen thumbnail (rendered by
## tools/render_stage_thumbs.gd) and a one-line description.
const STAGES := [
	{path = DEFAULT_STAGE, name = "Boxing Ring", thumb = "res://assets/ui/stages/ring.png",
		blurb = "Under the arena lights, in front of a packed house."},
	{path = DOJO_STAGE, name = "Dojo", thumb = "res://assets/ui/stages/dojo.png",
		blurb = "Tatami, paper screens and a hall full of students."},
	{path = ROOFTOP_STAGE, name = "Rooftop", thumb = "res://assets/ui/stages/rooftop.png",
		blurb = "A helipad high above the city lights."},
	{path = TEMPLE_STAGE, name = "Temple", thumb = "res://assets/ui/stages/temple.png",
		blurb = "A mountain courtyard at sunset, under falling blossom."},
	{path = BEACH_STAGE, name = "Beach", thumb = "res://assets/ui/stages/beach.png",
		blurb = "Sun, sand and turquoise surf, ringed by tiki torches."},
	{path = MARKET_STAGE, name = "Night Market", thumb = "res://assets/ui/stages/market.png",
		blurb = "A Manila street at dusk: grill smoke, jeepneys and fiesta flags."},
	{path = TRAIN_STAGE, name = "Express", thumb = "res://assets/ui/stages/train.png",
		blurb = "On the roof of an express train racing through the hills at sunset."},
	{path = COURTYARD_STAGE, name = "Kowloon Courtyard", thumb = "res://assets/ui/stages/courtyard.png",
		blurb = "An old tenement courtyard at dawn. The neighbours wake up as the sun climbs."},
]

const ROUNDS_TO_WIN := 2
const ROUND_TIME_SECONDS := 99

enum Mode { VS_CPU, VERSUS, TRAINING, ARCADE, ONLINE, DEMO, REPLAY, COACH }

var roster: Array[CharacterData] = []
## VS_CPU: P2 is the AI. VERSUS: P2 is a second local player. TRAINING: P2 is the
## training dummy (see scripts/training/training_mode.gd). ARCADE: a ladder of CPU
## opponents (see `arcade`). DEMO: two CPU fighters with no end (start_demo).
var mode: Mode = Mode.VS_CPU
var player_character: CharacterData
## P2's character (the CPU in VS_CPU mode, the second player in VERSUS).
var p2_character: CharacterData
var stage_path: String = DEFAULT_STAGE
## Seeds the CPU's decisions; the same seed and inputs replay the same match.
var match_seed := 1
## Coach mode (docs/ringside-plan.md): the adapter's WebSocket URL, from `-- --coach=ws://...`.
var coach_url := ""
## The Arcade run in progress (ARCADE mode), or null.
var arcade: ArcadeRun
## REPLAY: the saved match being watched.
var replay: Replay
## Stage preloaded by the loading screen, kept referenced so it stays in the resource
## cache until the fight scene loads it (the loading screen itself is freed first).
var preloaded_stage: Resource
## The stage already instantiated by the loading screen (on a worker thread: big stages
## took 200–400 ms on the main thread), for FightManager to take with take_stage_node().
var preloaded_stage_node: Node

const LOADING_SCENE := "res://scenes/loading_screen.tscn"

## The fighters' textures, loaded on background threads by the title screen and kept for
## the whole session (FighterModel.texture_paths: decoding them took ~6 s, repeated on
## every visit to character select because nothing else held them).
var _fighter_texture_paths := PackedStringArray()
var _fighter_textures: Array[Resource] = []
## Materials kept for the session so their generated shaders are too (keep_materials).
var _kept_materials := {}


func _ready() -> void:
	_load_roster()


## Starts loading every roster fighter's textures in the background (once per session).
func preload_fighters() -> void:
	if not _fighter_texture_paths.is_empty():
		return
	var unique := {}
	for character in roster:
		for path in FighterModel.texture_paths(character):
			unique[path] = true
	_fighter_texture_paths = PackedStringArray(unique.keys())
	for path in _fighter_texture_paths:
		ResourceLoader.load_threaded_request(path, "", true)


## How far preload_fighters() has got (0–1). Collects and keeps the textures once all
## are loaded, so call it until it returns 1.
func fighter_preload_progress() -> float:
	if _fighter_texture_paths.is_empty() or _fighter_textures.size() == _fighter_texture_paths.size():
		return 1.0
	var done := 0.0
	var finished := true
	for path in _fighter_texture_paths:
		var progress := []
		match ResourceLoader.load_threaded_get_status(path, progress):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				done += progress[0] if not progress.is_empty() else 0.0
				finished = false
			_: # loaded, or failed (FighterModel then loads it itself)
				done += 1.0
	if not finished:
		return done / _fighter_texture_paths.size()
	for path in _fighter_texture_paths:
		_fighter_textures.append(ResourceLoader.load_threaded_get(path))
	return 1.0


## The loading screen's instantiated stage if it is `path`'s, else null (the caller then
## instantiates it itself). Hands it over only once.
func take_stage_node(path: String) -> Node:
	var node := preloaded_stage_node
	preloaded_stage_node = null
	if node and node.scene_file_path != path:
		node.free()
		return null
	return node


## Holds one set of `materials` under `key` for the rest of the session. Godot frees a
## generated material's shader once nothing uses it, so each scene's first fighter used to
## rebuild its skin, hair and cloth shaders (~220 ms) and each fight its effect shaders,
## all while the loading screen sat frozen at 100%. FighterModel keeps one set per look,
## FightFx its particle materials.
func keep_materials(key: String, materials: Array) -> void:
	if not _kept_materials.has(key):
		_kept_materials[key] = materials


## Waits for any preload still running (quitting with loads in flight can crash on exit).
func _exit_tree() -> void:
	if preloaded_stage_node:
		preloaded_stage_node.free() # quit while the fight was about to start
	if _fighter_textures.size() < _fighter_texture_paths.size():
		for path in _fighter_texture_paths:
			ResourceLoader.load_threaded_get(path)


func _load_roster() -> void:
	roster.clear()
	# list_directory handles exported (.remap) resources, unlike DirAccess.
	for file in ResourceLoader.list_directory(CHARACTER_DIR):
		if not file.ends_with(".tres"):
			continue
		var data := load(CHARACTER_DIR + file) as CharacterData
		if data:
			roster.append(data)
	roster.sort_custom(func(a: CharacterData, b: CharacterData) -> bool: return a.select_order < b.select_order)


## Random CPU opponent, preferring someone other than the player.
func pick_random_cpu() -> CharacterData:
	var others := roster.filter(func(c: CharacterData) -> bool: return c != player_character)
	if others.is_empty():
		return player_character
	return others.pick_random()


## Goes to the fight through the loading screen (wallpaper + progress bar).
func go_to_fight(tree: SceneTree) -> void:
	tree.change_scene_to_file(LOADING_SCENE)


## Demo mode: two random fighters (different ones when possible) on a random stage, both
## played by the CPU, through the loading screen. DemoMode calls it again for the next one.
func start_demo(tree: SceneTree) -> void:
	mode = Mode.DEMO
	player_character = roster.pick_random()
	p2_character = pick_random_cpu()
	stage_path = (STAGES.pick_random() as Dictionary).path
	match_seed = randi()
	go_to_fight(tree)


## Coach mode from the command line: `-- --coach=ws://127.0.0.1:8797 --p1=jin --p2=kenji
## --stage=rooftop --seed=7`. Both fighters are CoachControllers driven over the link
## (docs/ringside-plan.md). Returns false when no --coach argument was given.
func start_coach(tree: SceneTree) -> bool:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.substr(2, arg.find("=") - 2)] = arg.substr(arg.find("=") + 1)
	if not args.has("coach"):
		return false
	mode = Mode.COACH
	coach_url = str(args.coach)
	player_character = _character_by_id(str(args.get("p1", ""))) if args.has("p1") else roster.pick_random()
	p2_character = _character_by_id(str(args.get("p2", ""))) if args.has("p2") else pick_random_cpu()
	if player_character == null or p2_character == null:
		push_error("coach: unknown fighter id (have %s)" % ", ".join(roster.map(func(c: CharacterData) -> String: return String(c.id))))
		tree.quit(2)
		return true
	stage_path = DEFAULT_STAGE
	if args.has("stage"):
		for stage: Dictionary in STAGES:
			if str(stage.path).get_file().get_basename() == str(args.stage) or stage.name.to_lower() == str(args.stage).to_lower():
				stage_path = stage.path
	match_seed = int(args.seed) if args.has("seed") else randi()
	# `--graphics=high|showcase` (default high) for this run only, like the window.
	var quality := ["low", "medium", "high", "showcase"].find(str(args.get("graphics", "high")))
	Settings.graphics = (quality if quality >= 0 else Settings.Graphics.HIGH) as Settings.Graphics
	# `--motion-blur=off|subtle|cinematic` (default cinematic: coached matches are watched);
	# `film` for a film-quality recording (240 rendered frames a second, blended by the adapter).
	var blur := ["off", "subtle", "cinematic", "film"].find(str(args.get("motion-blur", "cinematic")))
	Settings.motion_blur = (blur if blur >= 0 else MotionBlur.Level.CINEMATIC) as MotionBlur.Level
	_apply_coach_window(str(args.get("window", "1080p")), tree)
	tree.change_scene_to_file.call_deferred("res://scenes/fight.tscn")
	return true


## `--window=720p|900p|1080p|1440p|fullscreen` for a coached match (default 1080p): the
## window for this run only, sized in screen points (times the display scale, so 1080p is
## 3840×2160 pixels on a 2× Retina screen) and the 3D drawn at the window's own resolution;
## nothing is saved to the player's settings. A size that does not fit the screen falls
## back to the largest that does.
func _apply_coach_window(choice: String, tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var names := ["720p", "900p", "1080p", "1440p"]
	# High draws the 3D at 1080p and upscales it to the window (MetalFX on a Mac), which pays
	# for its light; Showcase and the lower presets keep their own scale over the native size.
	Settings.resolution = Settings.RESOLUTIONS.find(1080) if Settings.graphics == Settings.Graphics.HIGH else Settings.RESOLUTIONS.size() - 1
	if choice == "fullscreen":
		Settings.display_mode = Settings.DisplayMode.BORDERLESS
		Settings.apply_display()
	else:
		var index := names.find(choice)
		if index < 0:
			push_warning("coach: unknown --window=%s; using 1080p" % choice)
			index = 2
		Settings.display_mode = Settings.DisplayMode.WINDOWED
		Settings.window_size = index
		Settings.apply_display()
		var screen := DisplayServer.window_get_current_screen()
		# A film-quality recording renders four times the frames: its window is the size in
		# pixels, not screen points (1080p, not 4K on a Retina screen), to keep the movie small.
		var scale := 1.0 if Settings.motion_blur == MotionBlur.Level.FILM else maxf(1.0, DisplayServer.screen_get_scale(screen))
		var area := DisplayServer.screen_get_usable_rect(screen)
		var size := Vector2i(Settings.WINDOW_SIZES[0] * scale)
		for i in range(index, -1, -1):
			var candidate := Vector2i(Settings.WINDOW_SIZES[i] * scale)
			if candidate.x <= area.size.x and candidate.y <= area.size.y:
				size = candidate
				break
		DisplayServer.window_set_size(size)
		DisplayServer.window_set_position(area.position + (area.size - size) / 2)
	Settings.apply_graphics(tree.root)
	var size_now := DisplayServer.window_get_size()
	print("coach: window %s, %dx%d pixels (screen %s at %.1fx), graphics %s, 3D at %d%% (%s)" % [["windowed", "minimized", "maximized", "fullscreen", "exclusive fullscreen"][DisplayServer.window_get_mode()], size_now.x, size_now.y, DisplayServer.screen_get_size(), DisplayServer.screen_get_scale(), Settings.GRAPHICS_NAMES[Settings.graphics], roundi(tree.root.scaling_3d_scale * 100), ["bilinear", "FSR", "FSR 2", "MetalFX spatial", "MetalFX temporal"][tree.root.scaling_3d_mode]])


func _character_by_id(id: String) -> CharacterData:
	for character in roster:
		if String(character.id) == id:
			return character
	return null


## Watches a saved replay (Replay.problem() must be empty): its fighters and stage,
## through the loading screen.
func start_replay(tree: SceneTree, saved: Replay) -> void:
	mode = Mode.REPLAY
	replay = saved
	for character in roster:
		if String(character.id) == str(saved.meta.p1):
			player_character = character
		if String(character.id) == str(saved.meta.p2):
			p2_character = character
	stage_path = str(saved.meta.stage)
	go_to_fight(tree)


## Starts an Arcade run with `character` and sets up its first opponent.
func start_arcade(character: CharacterData) -> void:
	player_character = character
	arcade = ArcadeRun.create(character, roster, Settings.ai_difficulty, randi(), arcade_arenas(), DOJO_STAGE)
	apply_arcade_stage()


func apply_arcade_stage() -> void:
	p2_character = arcade.current().character
	stage_path = arcade.current().stage_path


func stage_paths() -> Array:
	return STAGES.map(func(s: Dictionary) -> String: return s.path)


## Stages for Arcade's regular fights: every stage except the boss's (the dojo), so a
## run visits all of them.
func arcade_arenas() -> Array:
	return stage_paths().filter(func(path: String) -> bool: return path != DOJO_STAGE)


## Display name of a stage scene (for the VS screen etc.).
func stage_name(path: String) -> String:
	for stage: Dictionary in STAGES:
		if stage.path == path:
			return stage.name
	return ""


func is_arcade() -> bool:
	return mode == Mode.ARCADE and arcade != null


func is_online() -> bool:
	return mode == Mode.ONLINE


func game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))


## A hash of every character's stats and moves. Online peers must match exactly, or the
## same inputs would play out differently on each machine.
func content_hash() -> int:
	var parts := []
	for character in roster:
		parts.append(_stored_values(character))
		for move in character.moves:
			parts.append(_stored_values(move))
	return hash(var_to_bytes(parts)) & 0xFFFFFFFF


func _stored_values(resource: Resource) -> Array:
	var out := []
	for property in resource.get_property_list():
		var key: String = property.name
		if not (property.usage & PROPERTY_USAGE_STORAGE) or key.begins_with("resource_") or key == "script":
			continue
		var value: Variant = resource.get(key)
		if value is Resource:
			value = (value as Resource).resource_path
		elif value is Array:
			value = (value as Array).map(func(v: Variant) -> Variant: return v.resource_path if v is Resource else v)
		out.append([key, value])
	return out


## Fills missing selections so a scene can be run directly from the editor (F6).
func ensure_selections() -> void:
	if player_character == null and not roster.is_empty():
		player_character = roster[0]
	if p2_character == null:
		p2_character = pick_random_cpu()
