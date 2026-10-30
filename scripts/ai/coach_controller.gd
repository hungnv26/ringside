class_name CoachController
extends AIController
## A CPU fighter coached from outside (docs/ringside-plan.md). The frame-level play is the
## AIController's, on Hard; the coach (an AI model, through CoachLink) tunes its knobs with a
## plan, queues named moves, and gives it a caption. Nothing here touches fighter state: the
## coach plays by the same packed inputs as everyone else.

## Preferred range names, in metres (AIController's CLOSE_RANGE is 1.2, FAR_RANGE 2.2).
const RANGES := {close = 0.9, mid = 1.6, far = 2.6}
## Reaction delays, in ticks (Hard is 8, Normal 14).
const REACTIONS := {fast = 6, normal = 10, slow = 16}
const OPTION_KEYS := ["poke", "string", "rush", "dash", "jump", "throw", "grab", "fireball",
	"ground_special", "sidestep", "wait", "retreat", "approach", "stance", "reversal", "glide"]
const MAX_QUEUE := 8
const MAX_CAPTION := 60
const MAX_RULES := 12
const RULE_INTERVAL := 10
const RULE_COOLDOWN := 45
const OPPONENT_STATES := ["idle", "attacking", "recovering", "blocking", "knocked_down", "jumping", "stunned"]

## The last plan applied, merged (what the coach is told it is running).
var plan := {}
var plan_id := ""
## Ticks since the last plan was applied.
var plan_age := 0
var caption := ""
## Named moves the coach queued, done in order when the fighter is actionable.
var queued: Array[String] = []
## Self-coding mode (docs/ringside-plan.md phase 4): rules the coach wrote, checked every
## RULE_INTERVAL ticks when the fighter is free; a matching rule queues its moves. Each rule:
## {name, when: {range, opponent, opponent_cornered, cornered, meter_full, health_below,
## opponent_health_below}, do: [moves], weight}.
var rules: Array[Dictionary] = []
## Beat mode: nothing happens by itself; only queued moves are performed (no AI decisions,
## no reactive blocking). The coach picks every move.
var manual := false
## The last rule that fired (its name), for the observation.
var last_rule := ""
var _rule_tick := 0
var _rule_cooldown := {} # rule index -> tick it may fire again
var _base_weights := {}


func _init(seed_value: int = 1) -> void:
	super(Difficulty.HARD, seed_value)


func attach(fighter: Fighter) -> void:
	super.attach(fighter)
	# A copy: PERSONALITIES is a shared constant and plans change the weights in place.
	personality = personality.duplicate(true)
	_base_weights = (personality.weights as Dictionary).duplicate()
	plan = _current_plan()


func reset() -> void:
	super.reset()
	queued.clear()


func read(fighter: Fighter) -> int:
	plan_age += 1
	_rule_tick += 1
	if _plan.is_empty() and not queued.is_empty() and fighter.is_actionable():
		_queue_named(queued.pop_front(), fighter)
	if manual:
		# Beat mode: queued steps only; otherwise stand still.
		if not _plan.is_empty():
			return _without_accidental_dash(_next_plan_input())
		return InputBuffer.pack(InputBuffer.NEUTRAL, 0)
	if _plan.is_empty() and queued.is_empty() and not rules.is_empty() and fighter.is_actionable() 			and _rule_tick % RULE_INTERVAL == 0:
		_apply_rules(fighter)
	return super.read(fighter)


## Applies a plan (every key optional; unknown keys are reported). Returns the errors.
func apply_plan(new_plan: Dictionary, id: String = "") -> Array[String]:
	var errors: Array[String] = []
	for key in new_plan:
		var value = new_plan[key]
		match String(key):
			"aggression":
				aggression = _unit(value, errors, "aggression")
			"block":
				block_chance = _unit(value, errors, "block")
			"punish":
				punish_chance = _unit(value, errors, "punish")
			"anti_air":
				anti_air_chance = _unit(value, errors, "anti_air")
			"pressure":
				personality.pressure = _unit(value, errors, "pressure")
			"range":
				if value is String and RANGES.has(value):
					personality.preferred_range = RANGES[value]
				elif value is float or value is int:
					personality.preferred_range = clampf(float(value), 0.5, 3.5)
				else:
					errors.append("range must be close, mid, far or metres")
			"reaction":
				if value is String and REACTIONS.has(value):
					reaction_frames = REACTIONS[value]
					block_reaction_frames = maxi(3, REACTIONS[value] / 2)
				else:
					errors.append("reaction must be fast, normal or slow")
			"options":
				if value is Dictionary:
					for option in value:
						if String(option) in OPTION_KEYS:
							var scale := clampf(float(value[option]), 0.0, 3.0)
							personality.weights[option] = float(_base_weights.get(option, 1.0)) * scale
						else:
							errors.append("unknown option %s" % option)
				else:
					errors.append("options must be an object of weights")
			_:
				errors.append("unknown plan key %s" % key)
	plan = _current_plan()
	plan_id = id
	plan_age = 0
	return errors


## Queues named moves (docs/ringside-plan.md "queue"). Unknown names are reported; the
## rest are kept, at most MAX_QUEUE in all.
func queue_moves(moves: Array, fighter: Fighter) -> Array[String]:
	var errors: Array[String] = []
	for entry in moves:
		var name := String(entry).strip_edges()
		if not _known_move(name, fighter):
			errors.append("unknown move %s" % name)
		elif queued.size() >= MAX_QUEUE:
			errors.append("queue full, dropped %s" % name)
		else:
			queued.append(name)
	return errors


## Replaces the rule set (self-coding mode). Returns the problems; bad rules are dropped.
func set_rules(new_rules: Array, fighter: Fighter) -> Array[String]:
	var errors: Array[String] = []
	var kept: Array[Dictionary] = []
	for entry in new_rules:
		if kept.size() >= MAX_RULES:
			errors.append("at most %d rules" % MAX_RULES)
			break
		if not entry is Dictionary:
			errors.append("a rule must be an object")
			continue
		var rule: Dictionary = entry
		var name := str(rule.get("name", "rule %d" % (kept.size() + 1)))
		var when = rule.get("when", {})
		if not when is Dictionary:
			errors.append("%s: when must be an object" % name)
			continue
		var moves = rule.get("do", [])
		if not moves is Array or moves.is_empty():
			errors.append("%s: do must list moves" % name)
			continue
		var ok := true
		for move in moves:
			if not _known_move(String(move).strip_edges(), fighter):
				errors.append("%s: unknown move %s" % [name, move])
				ok = false
		for key in when:
			match String(key):
				"range":
					if not when[key] in RANGES.keys():
						errors.append("%s: range must be close, mid or far" % name)
						ok = false
				"opponent":
					if not when[key] in OPPONENT_STATES:
						errors.append("%s: opponent must be one of %s" % [name, ", ".join(OPPONENT_STATES)])
						ok = false
				"opponent_cornered", "cornered", "meter_full":
					if not when[key] is bool:
						errors.append("%s: %s must be true or false" % [name, key])
						ok = false
				"health_below", "opponent_health_below":
					if not (when[key] is float or when[key] is int):
						errors.append("%s: %s must be a number 0..1" % [name, key])
						ok = false
				_:
					errors.append("%s: unknown condition %s" % [name, key])
					ok = false
		if ok:
			kept.append({name = name, when = when, do = moves.slice(0, 4).map(func(m) -> String: return String(m).strip_edges()),
				weight = clampf(float(rule.get("weight", 1.0)), 0.0, 5.0)})
	rules = kept
	_rule_cooldown.clear()
	return errors


## Checks the rules against the fight and queues the moves of one that matches.
func _apply_rules(fighter: Fighter) -> void:
	var opponent := fighter.opponent
	var delta: Vector3 = opponent.position - fighter.position
	var dist := Vector2(delta.x, delta.z).length()
	var range_name := "close" if dist < CLOSE_RANGE else "mid" if dist < FAR_RANGE else "far"
	var opp_state := _opponent_state(opponent)
	var facts := {
		range = range_name, opponent = opp_state,
		opponent_cornered = opponent.is_pinned_against_bounds(-opponent.forward),
		cornered = fighter.is_pinned_against_bounds(-fighter.forward),
		meter_full = fighter.meter >= Fighter.MAX_METER,
		health = fighter.health / float(fighter.data.max_health),
		opponent_health = opponent.health / float(opponent.data.max_health),
	}
	var options: Array = []
	var total := 0.0
	for i in rules.size():
		if int(_rule_cooldown.get(i, 0)) > _rule_tick:
			continue
		var rule := rules[i]
		if _rule_matches(rule.when, facts) and rule.weight > 0.0:
			options.append([rule.weight, i])
			total += rule.weight
	if options.is_empty():
		return
	var roll := _rng.randf() * total
	for option in options:
		roll -= option[0]
		if roll <= 0.0:
			_fire_rule(option[1], fighter)
			return
	_fire_rule(options[-1][1], fighter)


func _fire_rule(index: int, fighter: Fighter) -> void:
	var rule := rules[index]
	_rule_cooldown[index] = _rule_tick + RULE_COOLDOWN
	last_rule = rule.name
	for move in rule.do:
		if queued.size() < MAX_QUEUE:
			queued.append(move)
	if _plan.is_empty() and not queued.is_empty() and fighter.is_actionable():
		_queue_named(queued.pop_front(), fighter)


static func _rule_matches(when: Dictionary, facts: Dictionary) -> bool:
	for key in when:
		match String(key):
			"range", "opponent":
				if facts[key] != when[key]:
					return false
			"opponent_cornered", "cornered", "meter_full":
				if facts[key] != bool(when[key]):
					return false
			"health_below":
				if not facts.health < float(when[key]):
					return false
			"opponent_health_below":
				if not facts.opponent_health < float(when[key]):
					return false
	return true


## What the opponent is doing, in the rules' words.
static func _opponent_state(opponent: Fighter) -> String:
	match opponent.state:
		Fighter.State.ATTACK:
			var move := opponent.current_move
			if move and opponent.state_frame <= move.startup + move.active:
				return "attacking"
			return "recovering"
		Fighter.State.BLOCKSTUN:
			return "blocking"
		Fighter.State.KNOCKDOWN, Fighter.State.GETUP:
			return "knocked_down"
		Fighter.State.JUMP, Fighter.State.JUMP_SQUAT:
			return "jumping"
		Fighter.State.HITSTUN, Fighter.State.AIR_HIT, Fighter.State.WALL_SPLAT:
			return "stunned"
	return "idle"


func set_caption(text: String) -> void:
	caption = text.strip_edges().left(MAX_CAPTION)


## The plan as the coach sees it: the live values, not what it sent.
func _current_plan() -> Dictionary:
	var options := {}
	for key in OPTION_KEYS:
		var base := float(_base_weights.get(key, 1.0))
		if base > 0.0:
			options[key] = snappedf(float((personality.weights as Dictionary).get(key, 1.0)) / base, 0.01)
	return {
		aggression = snappedf(aggression, 0.01), range = snappedf(personality.preferred_range, 0.01),
		block = snappedf(block_chance, 0.01), punish = snappedf(punish_chance, 0.01),
		anti_air = snappedf(anti_air_chance, 0.01), pressure = snappedf(float(personality.pressure), 0.01),
		reaction = REACTIONS.find_key(reaction_frames) if REACTIONS.values().has(reaction_frames) else reaction_frames,
		options = options,
	}


func _unit(value, errors: Array[String], key: String) -> float:
	if value is float or value is int:
		return clampf(float(value), 0.0, 1.0)
	errors.append("%s must be a number 0..1" % key)
	return 0.5


static func _timed(name: String) -> Array:
	var parts := name.split(" ", false)
	return [parts[0], clampi(int(parts[1]) if parts.size() > 1 else 10, 1, 120)]


func _known_move(name: String, fighter: Fighter) -> bool:
	var timed := _timed(name)
	if timed[0] in ["block", "crouch_block", "wait", "approach", "retreat"]:
		return true
	if name in ["throw", "dash", "backdash", "jump", "jump_in", "sidestep"]:
		return true
	return fighter._move_for_input(name) != null or _moves.has(name)


## Turns a named move into plan steps, the way the AI's own options do.
func _queue_named(name: String, fighter: Fighter) -> void:
	var timed := _timed(name)
	match timed[0]:
		"block", "retreat":
			_plan.append([4, 0, timed[1]])
			return
		"crouch_block":
			_plan.append([1, 0, timed[1]])
			return
		"wait":
			_plan.append([5, 0, timed[1]])
			return
		"approach":
			_plan.append([6, 0, timed[1]])
			return
	match name:
		"throw":
			_queue_throw()
		"dash":
			_queue_dash()
		"backdash":
			_queue_backdash()
		"jump":
			_plan.append_array([[8, 0, 5], [5, 0, 24]])
		"jump_in":
			_queue_jump_in()
		"sidestep":
			_queue_sidestep()
		_:
			var move: MoveData = _moves.get(name, fighter._move_for_input(name))
			if move == null:
				return
			if move.is_special():
				_queue_special(move)
			elif name.begins_with("j."):
				_plan.append_array([[9, 0, 5], [5, 0, 9]])
				_queue_press(_button_of(name.substr(2)))
				_plan.append([5, 0, 16])
			else:
				var dir := 5
				var button_name := name
				if name.length() > 2 and name[0].is_valid_int():
					dir = int(name[0])
					button_name = name.substr(1)
				_queue_press(_button_of(button_name), dir)


static func _button_of(button_name: String) -> int:
	var found = InputBuffer.BUTTON_NAMES.find_key(button_name)
	return int(found) if found != null else InputBuffer.LP
