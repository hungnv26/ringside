class_name CoachLink
extends Node
## The game's end of the coach protocol (docs/ringside-plan.md "Protocol"): one WebSocket
## to the adapter. Sends `hello` once, `state` four times a second while a round is live,
## and `event`s; applies the adapter's `plan`, `queue` and `say` frames to the
## CoachControllers and answers each with `applied`; quits the game on `end`. Without a
## URL (tests) it builds the same frames and sends nothing.

const VERSION := 1
const STATE_EVERY := 15
const RECENT := 8
## After the match, the adapter sends `end`; failing that the window closes by itself
## (sooner with `--quit-after-match`, once the result has been on screen a moment).
const QUIT_AFTER_MATCH_TICKS := 30 * 60
const QUIT_FLAG_TICKS := 5 * 60
const SIDES := ["p1", "p2"]
## A beat hold ends by itself after this long without `resume` (wall clock).
const HOLD_TIMEOUT_MS := 45_000
## `-- --capture-dir=DIR` saves a screenshot this often during the fight (and at the result).
const CAPTURE_EVERY := 10 * 60
const LEVEL_NAMES := ["high", "mid", "low", "overhead"]

var manager: Node
var controllers: Array[CoachController] = []
var url := ""
## Frames that would have been sent (tests read them; kept short).
var sent: Array[Dictionary] = []

var _peer: WebSocketPeer
var _open := false
var _hello_sent := false
var _recent := [[], []] # per side: [{input, name, outcome}], newest last
var _last_phase := -1
var _last_state := [-1, -1]
var _match_over_ticks := -1
var _captions: Array[Label] = []
var _thinking: Array[Label] = []
## Model per side ("provider:model"), from the adapter's `models` frame; shown on the HUD.
var models := ["", ""]
## coach (default), script (self-coding: rules between rounds) or beat (the game pauses every
## `beat_ticks` until both coaches have picked). From the adapter's `mode` frame.
var mode := "coach"
var beat_ticks := 60
var beat_n := 0
var holding := false
var _hold_since_ms := 0
## Per side, per round: attacks by input -> {hit, counter, blocked, whiffed}, throws, knockdowns.
var _tally := [{}, {}]
var _capture_dir := ""
var _captures := 0


func setup(fight_manager: Node, link_url: String, coached: Array[CoachController]) -> void:
	manager = fight_manager
	url = link_url
	controllers = coached
	manager.ticked.connect(_on_ticked)
	manager.hit_landed.connect(_on_hit)
	manager.throw_landed.connect(_on_throw)
	manager.round_ended.connect(_on_round_ended)
	for i in manager.fighters.size():
		var fighter: Fighter = manager.fighters[i]
		fighter.attack_started.connect(_on_attack_started.bind(i))
		fighter.super_started.connect(_on_super_started)
	_build_captions()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			_capture_dir = arg.substr(14)
			DirAccess.make_dir_recursive_absolute(_capture_dir)
	if url != "":
		_peer = WebSocketPeer.new()
		var err := _peer.connect_to_url(url)
		if err != OK:
			push_warning("CoachLink: cannot connect to %s (%s)" % [url, error_string(err)])
			_peer = null


func _process(_delta: float) -> void:
	if holding and (Time.get_ticks_msec() - _hold_since_ms > HOLD_TIMEOUT_MS or _peer == null):
		print("CoachLink: beat %d: no resume from the adapter; going on" % beat_n)
		_resume()
	if _peer == null:
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _open:
				_open = true
				print("CoachLink: connected to ", url)
			if not _hello_sent:
				_send(hello())
				_hello_sent = true
			while _peer.get_available_packet_count() > 0:
				var text := _peer.get_packet().get_string_from_utf8()
				var msg = JSON.parse_string(text)
				if msg is Dictionary:
					_handle(msg)
		WebSocketPeer.STATE_CLOSED:
			if _open:
				print("CoachLink: link closed (%d %s)" % [_peer.get_close_code(), _peer.get_close_reason()])
			_open = false
			_peer = null


# --- Frames out ------------------------------------------------------------------

func hello() -> Dictionary:
	var fighters: Array = manager.fighters
	var gs := _game_state()
	return {
		type = "hello", version = VERSION,
		p1 = fighter_info(fighters[0].data), p2 = fighter_info(fighters[1].data),
		stage = gs.stage_name(gs.stage_path),
		rounds_to_win = gs.ROUNDS_TO_WIN, round_seconds = gs.ROUND_TIME_SECONDS,
		seed = gs.match_seed,
	}


## Looked up at run time: tests compile this class before the autoloads exist.
func _game_state() -> Node:
	return get_tree().root.get_node("GameState")


static func fighter_info(data: CharacterData) -> Dictionary:
	var moves: Array = []
	for move: MoveData in data.moves:
		if move.input.begins_with("~"):
			continue # follow-ups happen by themselves
		var notes: Array[String] = []
		if move.launches: notes.append("launcher")
		if move.knockdown: notes.append("knockdown")
		if move.invuln_frames > 0: notes.append("invincible %d frames" % move.invuln_frames)
		if move.projectile_speed > 0.0: notes.append("projectile")
		if move.super_move: notes.append("super, needs full meter")
		if move.command_grab: notes.append("command grab, unblockable")
		if move.reversal: notes.append("reversal stance")
		if move.focus_gain > 0: notes.append("power-up stance")
		if move.travel > 0.0 or move.lunge > 0.0: notes.append("moves forward")
		if move.low_profile: notes.append("ducks under highs")
		moves.append({
			input = move.input, name = move.name, startup = move.startup, active = move.active,
			recovery = move.recovery, damage = move.damage,
			level = "throw" if move.command_grab else LEVEL_NAMES[move.hit_level],
			notes = ", ".join(notes),
		})
	moves.append({input = "throw", name = "Throw", startup = Fighter.THROW_STARTUP, active = 1,
		recovery = Fighter.THROW_WHIFF_RECOVERY, damage = data.throw_damage, level = "throw",
		notes = "unblockable, techable; close range"})
	return {id = String(data.id), name = data.display_name, archetype = data.archetype,
		max_health = data.max_health, moves = moves}


func state() -> Dictionary:
	var fighters: Array = manager.fighters
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	var delta: Vector3 = b.position - a.position
	return {
		type = "state", tick = manager.phase_ticks, round = manager.round_number,
		timer = ceili(manager.timer_ticks / 60.0), wins = [manager.round_wins[0], manager.round_wins[1]],
		p1 = side_state(0), p2 = side_state(1),
		distance = snappedf(Vector2(delta.x, delta.z).length(), 0.01),
	}


func side_state(index: int) -> Dictionary:
	var fighter: Fighter = manager.fighters[index]
	var controller := controllers[index] if index < controllers.size() else null
	var recent: Array = _recent[index]
	return {
		health = fighter.health, max_health = fighter.data.max_health,
		meter = fighter.meter, max_meter = Fighter.MAX_METER,
		state = String(Fighter.State.keys()[fighter.state]).to_lower(),
		move = fighter.current_move.input if fighter.state == Fighter.State.ATTACK and fighter.current_move else null,
		x = snappedf(fighter.position.x, 0.01),
		cornered = fighter.is_pinned_against_bounds(-fighter.forward),
		plan_age_ticks = controller.plan_age if controller else 0,
		queued = controller.queued.duplicate() if controller else [],
		recent = recent.slice(maxi(0, recent.size() - RECENT)),
	}


func _event(name: String, fields: Dictionary) -> void:
	var frame := {type = "event", tick = manager.phase_ticks, event = name}
	frame.merge(fields)
	_send(frame)


func _send(frame: Dictionary) -> void:
	if sent.size() >= 64:
		sent.pop_front()
	sent.append(frame)
	if _peer and _open:
		_peer.send_text(JSON.stringify(frame))


# --- Frames in -------------------------------------------------------------------

func _handle(msg: Dictionary) -> void:
	var side := SIDES.find(str(msg.get("side", "")))
	match str(msg.get("type", "")):
		"plan":
			if side < 0:
				return
			var errors := controllers[side].apply_plan(msg.get("plan", {}) if msg.get("plan") is Dictionary else {}, str(msg.get("plan_id", "")))
			_applied(side, msg, errors)
		"queue":
			if side < 0:
				return
			var moves = msg.get("moves", [])
			var errors := controllers[side].queue_moves(moves if moves is Array else [], manager.fighters[side])
			_applied(side, msg, errors)
		"say":
			if side < 0:
				return
			controllers[side].set_caption(str(msg.get("text", "")))
			_show_caption(side, controllers[side].caption)
		"models":
			for i in 2:
				models[i] = str(msg.get(SIDES[i], ""))
			_show_models()
		"mode":
			mode = str(msg.get("mode", "coach"))
			beat_ticks = clampi(int(msg.get("beat_ticks", 60)), 15, 600)
			for controller in controllers:
				controller.manual = mode == "beat"
			print("CoachLink: mode ", mode, " (beat every %d ticks)" % beat_ticks if mode == "beat" else "")
		"policy":
			if side < 0:
				return
			var errors: Array[String] = []
			if msg.get("plan") is Dictionary:
				errors.append_array(controllers[side].apply_plan(msg.plan, str(msg.get("plan_id", ""))))
			if msg.get("rules") is Array:
				errors.append_array(controllers[side].set_rules(msg.rules, manager.fighters[side]))
			_applied(side, msg, errors)
		"resume":
			if holding and int(msg.get("n", beat_n)) == beat_n:
				_resume()
		"thinking":
			if side < 0:
				return
			_show_thinking(side, bool(msg.get("on", false)))
		"end":
			print("CoachLink: end (%s)" % str(msg.get("reason", "")))
			get_tree().quit()


func _applied(side: int, msg: Dictionary, errors: Array[String]) -> void:
	_send({type = "applied", side = SIDES[side], plan_id = str(msg.get("plan_id", "")),
		ok = errors.is_empty(), error = "; ".join(errors)})


# --- Observation -----------------------------------------------------------------

func _on_ticked() -> void:
	var phase: int = manager.phase
	if phase != _last_phase:
		_last_phase = phase
		if phase == manager.Phase.FIGHT:
			_recent = [[], []]
			_tally = [{}, {}]
			beat_n = 0
			_event("round_start", {round = manager.round_number})
			_send(state())
		elif phase == manager.Phase.MATCH_OVER:
			var winner: Fighter = manager.match_winner
			_event("match_end", {winner = SIDES[manager.fighters.find(winner)] if winner else null,
				wins = [manager.round_wins[0], manager.round_wins[1]],
				reason = "rounds" if winner else "draw"})
			_match_over_ticks = 0
	for i in 2:
		var fighter: Fighter = manager.fighters[i]
		if fighter.state != _last_state[i]:
			if fighter.state == Fighter.State.KNOCKDOWN:
				_tally[i]["knockdowns"] = int(_tally[i].get("knockdowns", 0)) + 1
				_event("knockdown", {side = SIDES[i]})
			_last_state[i] = fighter.state
		var recent: Array = _recent[i]
		if not recent.is_empty() and recent[-1].outcome == "pending" and fighter.state != Fighter.State.ATTACK:
			_resolve(i, recent[-1], "whiffed")
	if phase == manager.Phase.FIGHT and manager.phase_ticks % STATE_EVERY == 0:
		_send(state())
	if mode == "beat" and phase == manager.Phase.FIGHT and manager.phase_ticks % beat_ticks == 0 and _peer != null:
		_hold()
	if _capture_dir != "" and ((phase == manager.Phase.FIGHT and manager.phase_ticks % CAPTURE_EVERY == CAPTURE_EVERY - 1) or _match_over_ticks == 4 * 60):
		_capture()
	if _match_over_ticks >= 0:
		_match_over_ticks += 1
		var limit := QUIT_FLAG_TICKS if "--quit-after-match" in OS.get_cmdline_user_args() else QUIT_AFTER_MATCH_TICKS
		if _match_over_ticks == limit and _peer != null:
			print("CoachLink: closing after the match")
			get_tree().quit()


func _on_attack_started(move: MoveData, index: int) -> void:
	if move.input.begins_with("~"):
		return
	var recent: Array = _recent[index]
	recent.append({input = move.input, name = move.name, outcome = "pending"})
	if recent.size() > RECENT * 2:
		recent.pop_front()


func _on_hit(attacker: Fighter, defender: Fighter, move: MoveData, result: Fighter.HitResult) -> void:
	var index: int = manager.fighters.find(attacker)
	var outcome: String = ["hit", "blocked", "counter"][result]
	var recent: Array = _recent[index]
	if not recent.is_empty() and (recent[-1].outcome == "pending" or recent[-1].input == move.input):
		_resolve(index, recent[-1], outcome)
	# A follow-up (input "~...") happens by itself: name it, but give no input to copy.
	_event("hit", {attacker = SIDES[index], defender = SIDES[manager.fighters.find(defender)],
		input = "" if move.input.begins_with("~") else move.input, name = move.name, result = outcome,
		damage = move.damage, combo = defender.combo_hits})


## Sets an attack's outcome and counts it for the round summary.
func _resolve(index: int, entry: Dictionary, outcome: String) -> void:
	entry.outcome = outcome
	var attacks: Dictionary = _tally[index].get_or_add("attacks", {})
	var counts: Dictionary = attacks.get_or_add(entry.input, {hit = 0, counter = 0, blocked = 0, whiffed = 0})
	counts[outcome] = int(counts.get(outcome, 0)) + 1


## The round's numbers per side (the self-coding coach rewrites its rules from these).
func round_summary() -> Dictionary:
	var out := {}
	for i in 2:
		var fighter: Fighter = manager.fighters[i]
		var tally: Dictionary = _tally[i]
		out[SIDES[i]] = {
			attacks = tally.get("attacks", {}), throws = int(tally.get("throws", 0)),
			knockdowns = int(tally.get("knockdowns", 0)),
			health_left = fighter.health, max_health = fighter.data.max_health,
			rule_fired_last = controllers[i].last_rule if i < controllers.size() else "",
		}
	return out


func _on_throw(attacker: Fighter, defender: Fighter) -> void:
	_tally[manager.fighters.find(attacker)]["throws"] = int(_tally[manager.fighters.find(attacker)].get("throws", 0)) + 1
	_event("throw", {attacker = SIDES[manager.fighters.find(attacker)],
		defender = SIDES[manager.fighters.find(defender)]})


func _on_super_started(fighter: Fighter, move: MoveData) -> void:
	_event("super", {side = SIDES[manager.fighters.find(fighter)], name = move.name})


func _on_round_ended(winner: Fighter, reason: String) -> void:
	if holding:
		_resume()
	_event("round_end", {winner = SIDES[manager.fighters.find(winner)] if winner else null, reason = reason,
		round = manager.round_number, summary = round_summary()})


# --- Beat mode ---------------------------------------------------------------------

## Stops the simulation (the picture holds) and asks both coaches for their next moves.
func _hold() -> void:
	if holding:
		return
	holding = true
	beat_n += 1
	_hold_since_ms = Time.get_ticks_msec()
	manager.set_physics_process(false)
	var frame := state()
	frame.type = "beat"
	frame.n = beat_n
	_send(frame)


func _resume() -> void:
	holding = false
	manager.set_physics_process(true)


# --- Captions --------------------------------------------------------------------

func _build_captions() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	for i in 2:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8))
		label.add_theme_constant_override("outline_size", 7)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(520, 0)
		if i == 0:
			label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			label.grow_vertical = Control.GROW_DIRECTION_BEGIN
			label.offset_left = 28
			label.offset_bottom = -104
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		else:
			label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			label.grow_vertical = Control.GROW_DIRECTION_BEGIN
			label.offset_right = -28
			label.offset_bottom = -104
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.modulate.a = 0.0
		layer.add_child(label)
		_captions.append(label)
		var mark := Label.new()
		mark.text = "COACH THINKING"
		mark.add_theme_font_size_override("font_size", 12)
		mark.add_theme_color_override("font_color", Color(0.85, 0.8, 0.7))
		mark.add_theme_constant_override("outline_size", 5)
		mark.add_theme_color_override("font_outline_color", Color.BLACK)
		if i == 0:
			mark.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			mark.grow_vertical = Control.GROW_DIRECTION_BEGIN
			mark.offset_left = 28
			mark.offset_bottom = -82
		else:
			mark.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			mark.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			mark.grow_vertical = Control.GROW_DIRECTION_BEGIN
			mark.offset_right = -28
			mark.offset_bottom = -82
			mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		mark.visible = false
		layer.add_child(mark)
		_thinking.append(mark)


## "Jin · claude-haiku-5-5" on the name plates (the model without its provider).
func _show_models() -> void:
	if DisplayServer.get_name() == "headless" or manager.hud == null:
		return
	for i in 2:
		var label: Label = manager.hud.p1_name if i == 0 else manager.hud.p2_name
		var model: String = models[i].get_slice(":", 1) if models[i].contains(":") else models[i]
		var fighter: Fighter = manager.fighters[i]
		label.text = "%s · %s" % [fighter.data.display_name, model] if model != "" else "%s (AI)" % fighter.data.display_name


## A small "coach thinking" mark above the caption while the side's model is answering.
func _show_thinking(side: int, on: bool) -> void:
	if side >= _thinking.size():
		return
	_thinking[side].visible = on


func _show_caption(side: int, text: String) -> void:
	if side >= _captions.size():
		return
	var label := _captions[side]
	label.text = text
	label.modulate.a = 1.0
	var tween := label.create_tween()
	tween.tween_interval(6.0)
	tween.tween_property(label, "modulate:a", 0.0, 0.8)


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_captures += 1
	var path := "%s/ringside_%02d.png" % [_capture_dir, _captures]
	get_viewport().get_texture().get_image().save_png(path)
	print("CoachLink: captured ", path)
