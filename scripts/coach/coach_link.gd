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
## `-- --capture-dir=DIR` saves a screenshot this often during the fight (and at the result).
const CAPTURE_EVERY := 10 * 60
const LEVEL_NAMES := ["high", "mid", "low", "overhead"]
## A read (`predict`) must come true within this many ticks or it is a miss.
const PREDICT_TICKS := 6 * 60
const MAX_TALK := 140
## How long the corner talk, the plan chips and the read badge stay on screen (seconds).
const TALK_SECONDS := 7.0
const CHIP_SECONDS := 3.5
const BADGE_SECONDS := 2.5
const MAX_CHIPS := 4
## Words a read may use besides a move input, and how a move matches them.
const READ_WORDS := ["jump", "throw", "super", "fireball", "low", "overhead", "sweep", "reversal", "uppercut"]

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
var _talks: Array[Label] = []
var _chips: Array[Control] = []
var _badges: Array[Label] = []
var _card: PanelContainer
var _card_title: Label
var _card_grid: GridContainer
## Per side: the pending read {what, plan_id, until} or empty.
var _predictions := [{}, {}]
var _ticks := 0
var _super_landed := [false, false]
## Model per side ("provider:model"), from the adapter's `models` frame; shown on the HUD.
var models := ["", ""]
## coach (default) or script (self-coding: rules between rounds). From the adapter's `mode` frame.
var mode := "coach"
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
			var before: Dictionary = controllers[side].plan.duplicate(true)
			var errors := controllers[side].apply_plan(msg.get("plan", {}) if msg.get("plan") is Dictionary else {}, str(msg.get("plan_id", "")))
			_show_chips(side, plan_chips(before, controllers[side].plan))
			_applied(side, msg, errors)
		"queue":
			if side < 0:
				return
			var moves = msg.get("moves", [])
			var before := controllers[side].queued.size()
			var errors := controllers[side].queue_moves(moves if moves is Array else [], manager.fighters[side])
			var added: Array = controllers[side].queued.slice(before)
			if not added.is_empty():
				_show_chips(side, [queue_chip(added)])
			_applied(side, msg, errors)
		"say":
			if side < 0:
				return
			controllers[side].set_caption(str(msg.get("text", "")))
			_show_caption(side, controllers[side].caption)
		"talk":
			if side < 0:
				return
			_show_talk(side, str(msg.get("text", "")).strip_edges().left(MAX_TALK))
		"predict":
			if side < 0:
				return
			var errors := set_prediction(side, str(msg.get("what", "")), str(msg.get("plan_id", "")))
			_applied(side, msg, errors)
		"models":
			for i in 2:
				models[i] = str(msg.get(SIDES[i], ""))
			_show_models()
		"mode":
			mode = str(msg.get("mode", "coach"))
			print("CoachLink: mode ", mode)
		"policy":
			if side < 0:
				return
			var errors: Array[String] = []
			if msg.get("plan") is Dictionary:
				errors.append_array(controllers[side].apply_plan(msg.plan, str(msg.get("plan_id", ""))))
			if msg.get("rules") is Array:
				errors.append_array(controllers[side].set_rules(msg.rules, manager.fighters[side]))
			_applied(side, msg, errors)
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
	_ticks += 1
	var phase: int = manager.phase
	if phase != _last_phase:
		_last_phase = phase
		if phase == manager.Phase.FIGHT:
			_recent = [[], []]
			_tally = [{}, {}]
			_predictions = [{}, {}]
			_super_landed = [false, false]
			_hide_card()
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
			elif fighter.state == Fighter.State.JUMP:
				_check_read(1 - i, "jump", null)
			_last_state[i] = fighter.state
		var prediction: Dictionary = _predictions[i]
		if not prediction.is_empty() and _ticks >= int(prediction.until):
			_resolve_read(i, false, "")
		var recent: Array = _recent[i]
		if not recent.is_empty() and recent[-1].outcome == "pending" and fighter.state != Fighter.State.ATTACK:
			_resolve(i, recent[-1], "whiffed")
	if phase == manager.Phase.FIGHT and manager.phase_ticks % STATE_EVERY == 0:
		_send(state())
	if _capture_dir != "" and ((phase == manager.Phase.FIGHT and manager.phase_ticks % CAPTURE_EVERY == CAPTURE_EVERY - 1) or (phase == manager.Phase.ROUND_OVER and manager.phase_ticks == 90 + manager.round_over_ticks - manager.ROUND_OVER_TICKS) or _match_over_ticks == 4 * 60):
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
	if move.super_move:
		_tally[index]["supers_used"] = int(_tally[index].get("supers_used", 0)) + 1
		_super_landed[index] = false
	_check_read(1 - index, "", move)


func _on_hit(attacker: Fighter, defender: Fighter, move: MoveData, result: Fighter.HitResult) -> void:
	var index: int = manager.fighters.find(attacker)
	var outcome: String = ["hit", "blocked", "counter"][result]
	var recent: Array = _recent[index]
	if not recent.is_empty() and (recent[-1].outcome == "pending" or recent[-1].input == move.input):
		_resolve(index, recent[-1], outcome)
	if move.super_move and outcome != "blocked" and not _super_landed[index]:
		_super_landed[index] = true
		_tally[index]["supers_landed"] = int(_tally[index].get("supers_landed", 0)) + 1
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


## The round's numbers per side (the self-coding coach rewrites its rules from these; the
## round card shows them).
func round_summary() -> Dictionary:
	var out := {}
	for i in 2:
		var fighter: Fighter = manager.fighters[i]
		var tally: Dictionary = _tally[i]
		var totals := {hit = 0, counter = 0, blocked = 0, whiffed = 0}
		for counts: Dictionary in tally.get("attacks", {}).values():
			for key in totals:
				totals[key] += int(counts.get(key, 0))
		out[SIDES[i]] = {
			attacks = tally.get("attacks", {}), totals = totals, throws = int(tally.get("throws", 0)),
			knockdowns = int(tally.get("knockdowns", 0)),
			supers = {used = int(tally.get("supers_used", 0)), landed = int(tally.get("supers_landed", 0))},
			reads = {made = int(tally.get("reads_made", 0)), right = int(tally.get("reads_right", 0))},
			health_left = fighter.health, max_health = fighter.data.max_health,
			rule_fired_last = controllers[i].last_rule if i < controllers.size() else "",
		}
	return out


func _on_throw(attacker: Fighter, defender: Fighter) -> void:
	_tally[manager.fighters.find(attacker)]["throws"] = int(_tally[manager.fighters.find(attacker)].get("throws", 0)) + 1
	_event("throw", {attacker = SIDES[manager.fighters.find(attacker)],
		defender = SIDES[manager.fighters.find(defender)]})
	_check_read(manager.fighters.find(defender), "throw", null)


# --- Reads -------------------------------------------------------------------------

## A coach's call on what the opponent does next (`predict`): a move input from the
## opponent's list or one of READ_WORDS. One read at a time; a new one replaces the old,
## which then counts as a miss.
func set_prediction(side: int, what: String, plan_id: String) -> Array[String]:
	var errors: Array[String] = []
	if manager.phase != manager.Phase.FIGHT:
		errors.append("no read: the round is not live")
		return errors
	var word := what.strip_edges()
	var opponent: Fighter = manager.fighters[1 - side]
	var known := word.to_lower() in READ_WORDS
	if not known:
		for move: MoveData in opponent.data.moves:
			if move.input.to_upper() == word.to_upper():
				known = true
				word = move.input
				break
	if not known:
		errors.append("unknown read %s: use one of the opponent's move inputs or %s" % [word, ", ".join(READ_WORDS)])
		return errors
	if not _predictions[side].is_empty():
		_resolve_read(side, false, "replaced")
	_predictions[side] = {what = word, plan_id = plan_id, until = _ticks + PREDICT_TICKS}
	_tally[side]["reads_made"] = int(_tally[side].get("reads_made", 0)) + 1
	return errors


## Does the opponent's action (`word` for jump/throw, or an attack) fulfil the read?
static func read_matches(what: String, word: String, move: MoveData) -> bool:
	var w := what.to_lower()
	if move == null:
		return w == word
	match w:
		"super": return move.super_move
		"fireball": return move.projectile_speed > 0.0
		"low": return move.hit_level == MoveData.HitLevel.LOW
		"overhead": return move.hit_level == MoveData.HitLevel.OVERHEAD
		"sweep": return move.input == "2HK"
		"reversal": return move.invuln_frames > 0 or move.input.begins_with("623")
		"uppercut": return move.input == "2HP" or move.input.begins_with("623")
		"jump", "throw": return false
		_: return move.input.to_lower() == w


func _check_read(side: int, word: String, move: MoveData) -> void:
	if side < 0 or side > 1:
		return
	var prediction: Dictionary = _predictions[side]
	if prediction.is_empty():
		return
	if read_matches(str(prediction.what), word, move):
		_resolve_read(side, true, move.name if move else word)


func _resolve_read(side: int, right: bool, actual: String) -> void:
	var prediction: Dictionary = _predictions[side]
	_predictions[side] = {}
	if right:
		_tally[side]["reads_right"] = int(_tally[side].get("reads_right", 0)) + 1
		_show_badge(side, "CALLED IT · %s" % actual)
	_event("read", {side = SIDES[side], what = str(prediction.get("what", "")), right = right, actual = actual})


## Chips for what a plan frame changed: "block ↑ 0.95", "range → close", "throw ↑ 2".
static func plan_chips(before: Dictionary, after: Dictionary) -> Array[String]:
	var chips: Array[String] = []
	for key in after:
		if key == "options":
			continue
		var was = before.get(key)
		var now = after[key]
		if was == now:
			continue
		if now is float or now is int:
			var arrow := "→" if was == null else ("↑" if float(now) > float(was) else "↓")
			chips.append("%s %s %s" % [key, arrow, _num(now)])
		else:
			chips.append("%s → %s" % [key, str(now)])
	var options_before: Dictionary = before.get("options", {})
	for option in after.get("options", {}):
		var now := float(after.options[option])
		var was := float(options_before.get(option, 1.0))
		if is_equal_approx(now, was):
			continue
		chips.append("%s %s %s" % [option, "↑" if now > was else "↓", _num(now)])
	return chips.slice(0, MAX_CHIPS)


static func queue_chip(moves: Array) -> String:
	for move in moves:
		if move.contains("236236"):
			return "SUPER QUEUED · " + " › ".join(moves)
	return "QUEUE · " + " › ".join(moves)


static func _num(value) -> String:
	var f := float(value)
	return str(int(f)) if is_equal_approx(f, roundf(f)) else ("%.2f" % f).rstrip("0")


func _on_super_started(fighter: Fighter, move: MoveData) -> void:
	_event("super", {side = SIDES[manager.fighters.find(fighter)], name = move.name})


func _on_round_ended(winner: Fighter, reason: String) -> void:
	for i in 2:
		if not _predictions[i].is_empty():
			_resolve_read(i, false, "round over")
	var summary := round_summary()
	_event("round_end", {winner = SIDES[manager.fighters.find(winner)] if winner else null, reason = reason,
		round = manager.round_number, summary = summary})
	# After a K.O. the card waits for the replay (KOReplay) to finish.
	var replay = manager.get("ko_replay") # untyped: this script loads without the fight's autoloads in tests
	if reason.ends_with("K.O.") and replay and replay.call("_enabled"):
		replay.finished.connect(_show_card.bind(winner, reason, summary), CONNECT_ONE_SHOT)
	else:
		_show_card(winner, reason, summary)


# --- Corner stacks, chips, badges and the round card ------------------------------

## Per corner, from the bottom up: the COACH THINKING mark, the caption (`say`), the plan
## chips, the corner talk (`talk`) and the read badge. Plain text, no glow: real data only.
func _build_captions() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	for i in 2:
		var right := i == 1
		var stack := VBoxContainer.new()
		stack.custom_minimum_size = Vector2(520, 0)
		stack.add_theme_constant_override("separation", 6)
		stack.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT)
		stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
		if right:
			stack.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			stack.offset_right = -28
		else:
			stack.offset_left = 28
		stack.offset_bottom = -82
		layer.add_child(stack)

		var badge := _text_label(18, Color(0.98, 0.82, 0.45), right)
		badge.visible = false
		stack.add_child(badge)
		_badges.append(badge)

		var talk := _text_label(16, Color(0.88, 0.86, 0.82), right)
		talk.visible = false
		stack.add_child(talk)
		_talks.append(talk)

		var chips := HFlowContainer.new()
		chips.add_theme_constant_override("h_separation", 6)
		chips.add_theme_constant_override("v_separation", 4)
		chips.alignment = FlowContainer.ALIGNMENT_END if right else FlowContainer.ALIGNMENT_BEGIN
		chips.visible = false
		stack.add_child(chips)
		_chips.append(chips)

		var label := _text_label(22, Color(1.0, 0.95, 0.8), right)
		label.add_theme_constant_override("outline_size", 7)
		label.visible = false
		stack.add_child(label)
		_captions.append(label)

		var mark := _text_label(12, Color(0.85, 0.8, 0.7), right)
		mark.text = "COACH THINKING"
		mark.visible = false
		stack.add_child(mark)
		_thinking.append(mark)
	_build_card(layer)


static func _text_label(size: int, color: Color, right: bool) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	return label


## Shows a control at full opacity, then fades it out after `seconds` and hides it.
static func _fade(control: Control, seconds: float) -> void:
	if control.has_meta("fade"):
		var old = control.get_meta("fade")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	control.visible = true
	control.modulate.a = 1.0
	var tween := control.create_tween()
	tween.tween_interval(seconds)
	tween.tween_property(control, "modulate:a", 0.0, 0.6)
	tween.tween_callback(func() -> void: control.visible = false)
	control.set_meta("fade", tween)


## "Jin · claude-haiku-5-5" on the name plates (the model without its provider).
func _show_models() -> void:
	if DisplayServer.get_name() == "headless" or manager.hud == null:
		return
	for i in 2:
		var label: Label = manager.hud.p1_name if i == 0 else manager.hud.p2_name
		var model: String = models[i].get_slice(":", 1) if models[i].contains(":") else models[i]
		var fighter: Fighter = manager.fighters[i]
		label.text = "%s · %s" % [fighter.data.display_name, model] if model != "" else "%s (AI)" % fighter.data.display_name


## A small "coach thinking" mark under the caption while the side's model is answering.
func _show_thinking(side: int, on: bool) -> void:
	if side >= _thinking.size():
		return
	_thinking[side].visible = on


func _show_caption(side: int, text: String) -> void:
	if side >= _captions.size() or text == "":
		return
	_captions[side].text = text
	_fade(_captions[side], 6.0)


## The coach's own line about what it sees and what it is changing.
func _show_talk(side: int, text: String) -> void:
	if side >= _talks.size() or text == "":
		return
	_talks[side].text = text
	_fade(_talks[side], TALK_SECONDS)


func _show_chips(side: int, chips: Array[String]) -> void:
	if side >= _chips.size() or chips.is_empty():
		return
	var row: Control = _chips[side]
	for child in row.get_children():
		child.queue_free()
	for chip in chips:
		var label := Label.new()
		label.text = chip
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", Color(0.92, 0.9, 0.86))
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.06, 0.07, 0.09, 0.78)
		box.border_color = Color(0.42, 0.4, 0.36)
		box.set_border_width_all(1)
		box.set_corner_radius_all(3)
		box.content_margin_left = 7
		box.content_margin_right = 7
		box.content_margin_top = 2
		box.content_margin_bottom = 2
		label.add_theme_stylebox_override("normal", box)
		row.add_child(label)
	_fade(row, CHIP_SECONDS)


func _show_badge(side: int, text: String) -> void:
	if side >= _badges.size():
		return
	_badges[side].text = text
	_fade(_badges[side], BADGE_SECONDS)


## The card between rounds: both sides' numbers for the round that just ended.
func _build_card(layer: CanvasLayer) -> void:
	var band := CenterContainer.new()
	band.set_anchors_preset(Control.PRESET_FULL_RECT)
	band.anchor_top = 0.6
	band.anchor_bottom = 0.98
	band.offset_top = 0
	band.offset_bottom = 0
	layer.add_child(band)
	_card = PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.07, 0.08, 0.1, 0.9)
	box.border_color = Color(0.32, 0.33, 0.37)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 22
	box.content_margin_right = 22
	box.content_margin_top = 12
	box.content_margin_bottom = 14
	_card.add_theme_stylebox_override("panel", box)
	_card.visible = false
	band.add_child(_card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_card.add_child(column)
	_card_title = Label.new()
	_card_title.add_theme_font_size_override("font_size", 20)
	_card_title.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8))
	_card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_card_title)
	_card_grid = GridContainer.new()
	_card_grid.columns = 3
	_card_grid.add_theme_constant_override("h_separation", 26)
	_card_grid.add_theme_constant_override("v_separation", 2)
	column.add_child(_card_grid)


func _show_card(winner: Fighter, reason: String, summary: Dictionary) -> void:
	if _card == null:
		return
	var names: Array[String] = []
	for i in 2:
		var fighter: Fighter = manager.fighters[i]
		var model: String = models[i].get_slice(":", 1) if models[i].contains(":") else models[i]
		names.append("%s · %s" % [fighter.data.display_name, model] if model != "" else fighter.data.display_name)
	_card_title.text = "ROUND %d · %s" % [manager.round_number, ("%s WINS · %s" % [winner.data.display_name.to_upper(), reason]) if winner else reason]
	for child in _card_grid.get_children():
		child.queue_free()
	var p1: Dictionary = summary.p1
	var p2: Dictionary = summary.p2
	var rows: Array = [
		[names[0], "", names[1]],
		["%d%%" % roundi(100.0 * p1.health_left / p1.max_health), "Health left", "%d%%" % roundi(100.0 * p2.health_left / p2.max_health)],
		[str(p1.totals.hit + p1.totals.counter), "Hits landed", str(p2.totals.hit + p2.totals.counter)],
		[str(p1.totals.blocked), "Blocked by the other", str(p2.totals.blocked)],
		[str(p1.totals.whiffed), "Whiffed", str(p2.totals.whiffed)],
		[str(p1.throws), "Throws", str(p2.throws)],
		[str(p2.knockdowns), "Knockdowns dealt", str(p1.knockdowns)],
		["%d of %d" % [p1.supers.landed, p1.supers.used], "Supers landed", "%d of %d" % [p2.supers.landed, p2.supers.used]],
		["%d of %d" % [p1.reads.right, p1.reads.made], "Reads called", "%d of %d" % [p2.reads.right, p2.reads.made]],
	]
	for r in rows.size():
		for c in 3:
			var cell := Label.new()
			cell.text = str(rows[r][c])
			cell.add_theme_font_size_override("font_size", 17 if r == 0 else 16)
			cell.add_theme_color_override("font_color", Color(0.98, 0.82, 0.45) if r == 0 else (Color(0.72, 0.7, 0.66) if c == 1 else Color(0.95, 0.94, 0.9)))
			cell.horizontal_alignment = [HORIZONTAL_ALIGNMENT_RIGHT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_LEFT][c]
			cell.custom_minimum_size = Vector2(180 if c == 1 else 150, 0)
			_card_grid.add_child(cell)
	_card.visible = true


func _hide_card() -> void:
	if _card:
		_card.visible = false


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_captures += 1
	var path := "%s/ringside_%02d.png" % [_capture_dir, _captures]
	get_viewport().get_texture().get_image().save_png(path)
	print("CoachLink: captured ", path)
