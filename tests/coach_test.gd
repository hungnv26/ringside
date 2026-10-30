# Headless test of coach mode (docs/ringside-plan.md). Run:
#   godot --headless --path . -s res://tests/coach_test.gd
# Boots the fight scene in Mode.COACH with no link URL (CoachLink builds frames, sends
# nothing), applies plans and queues through the controllers, and checks the frames.
# Exit code 1 on failure.
extends SceneTree

var m
var p1: Fighter
var p2: Fighter
var fails := 0


func check(label: String, ok: bool, extra := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + label + ("  [" + extra + "]" if extra != "" else ""))
	if not ok:
		fails += 1


func step(n := 1) -> void:
	for i in n:
		m._physics_process(1.0 / 60.0)


func _initialize() -> void:
	await process_frame
	var gs = root.get_node("GameState")
	gs.mode = gs.Mode.COACH
	gs.coach_url = ""
	gs.player_character = gs._character_by_id("jin")
	gs.p2_character = gs._character_by_id("kenji")
	gs.match_seed = 7
	root.get_node("Settings").fight_intros = false
	change_scene_to_file("res://scenes/fight.tscn")
	await process_frame
	await process_frame
	m = current_scene
	m.set_physics_process(false)
	p1 = m.fighters[0]
	p2 = m.fighters[1]

	check("both fighters are coached", p1.controller is CoachController and p2.controller is CoachController)
	var link: CoachLink = m.coach_link
	check("link exists offline", link != null and link.url == "")
	var coach: CoachController = p1.controller

	# hello
	var hello := link.hello()
	var inputs: Array = hello.p1.moves.map(func(mv: Dictionary) -> String: return mv.input)
	check("hello lists Jin's moves with the throw", hello.p1.id == "jin" and "236K" in inputs and "throw" in inputs, ", ".join(inputs))
	check("hello has the match setup", hello.rounds_to_win == 2 and hello.round_seconds == 99 and hello.stage != "")
	var super_move: Dictionary = hello.p1.moves.filter(func(mv: Dictionary) -> bool: return mv.input == "236236K")[0]
	check("move notes mention the super", super_move.notes.contains("super"), super_move.notes)

	# plans
	var base_poke: float = coach._base_weights.get("poke", 1.0)
	var errors := coach.apply_plan({aggression = 0.9, range = "close", reaction = "fast", block = 0.2, options = {poke = 2.0}}, "plan-1")
	check("a full plan applies without errors", errors.is_empty(), ", ".join(errors))
	check("plan sets aggression", is_equal_approx(coach.aggression, 0.9), str(coach.aggression))
	check("plan sets the preferred range", is_equal_approx(coach.personality.preferred_range, 0.9))
	check("plan sets the reaction delay", coach.reaction_frames == 6 and coach.block_reaction_frames == 3)
	check("plan scales an option weight", is_equal_approx(coach.personality.weights.poke, base_poke * 2.0))
	check("the merged plan reads back", coach.plan.aggression == 0.9 and coach.plan.range == 0.9 and coach.plan.reaction == "fast" and coach.plan.options.poke == 2.0, str(coach.plan))
	check("plan id and age recorded", coach.plan_id == "plan-1" and coach.plan_age == 0)
	errors = coach.apply_plan({range = "nowhere", bogus = 1, aggression = "lots"})
	check("bad plan fields are each reported", errors.size() == 3, ", ".join(errors))
	check("a partial plan keeps other values", coach.reaction_frames == 6)
	check("the shared personality table is untouched", AIController.PERSONALITIES[&"jin"].weights.poke == base_poke)

	# queue
	errors = coach.queue_moves(["2HK", "throw", "nope", "block 12", "j.HK"], p1)
	check("unknown moves are refused, the rest queued", errors.size() == 1 and ", ".join(coach.queued) == "2HK, throw, block 12, j.HK", ", ".join(errors) + " | " + ", ".join(coach.queued))
	coach.queued.clear()

	# the queued sweep comes out and is seen in the frames
	m.start_match()
	m.start_fight_immediately()
	p2.controller = m.dummy
	m.dummy.mode = DummyController.Mode.STAND
	step(2)
	p1.position.x = p2.position.x - 1.0
	p1.reset_physics_interpolation()
	coach.apply_plan({aggression = 0.0, options = {wait = 3.0}})
	coach.queue_moves(["2HK"], p1)
	var saw_sweep := false
	for i in 90:
		step()
		if p1.state == Fighter.State.ATTACK and p1.current_move and p1.current_move.input == "2HK":
			saw_sweep = true
			break
	check("a queued move is performed", saw_sweep)
	step(60)
	var st := link.state()
	check("state frame has both sides and the distance", st.type == "state" and st.has("p1") and st.has("p2") and st.distance > 0.0)
	var recent: Array = st.p1.recent
	check("recent attacks carry the outcome", not recent.is_empty() and recent[-1].input == "2HK" and recent[-1].outcome in ["hit", "counter"], str(recent))
	check("the sweep did damage", p2.health < p2.data.max_health)
	var events: Array = link.sent.filter(func(f: Dictionary) -> bool: return f.type == "event").map(func(f: Dictionary) -> String: return f.event)
	check("round start and hit events were built", "round_start" in events and "hit" in events, ", ".join(events))
	check("states were built four times a second", link.sent.filter(func(f: Dictionary) -> bool: return f.type == "state").size() >= 5)
	check("state names are lower case", st.p1.state == st.p1.state.to_lower())

	# models and thinking frames (offline: no HUD change in headless, but the state is kept)
	link._handle({type = "models", p1 = "anthropic:claude-haiku-5-5", p2 = "fake:coach"})
	check("the models frame is kept per side", link.models[0] == "anthropic:claude-haiku-5-5" and link.models[1] == "fake:coach")
	link._handle({type = "thinking", side = "p2", on = true})
	check("a thinking frame for an unknown side is ignored", true)
	link._handle({type = "thinking", side = "nobody", on = true})

	# rules (self-coding mode)
	errors = coach.set_rules([
		{name = "punish", when = {range = "close", opponent = "recovering"}, do = ["2HP"], weight = 2},
		{name = "sweep", when = {range = "close"}, do = ["2HK"]},
		{name = "bad", when = {range = "nowhere"}, do = ["LP"]},
		{name = "bad2", when = {}, do = ["nope"]},
		{name = "super", when = {meter_full = true, range = "mid"}, do = ["236236K"]},
	], p1)
	check("bad rules are reported and dropped, good ones kept", errors.size() == 2 and coach.rules.size() == 3, ", ".join(errors) + " | %d kept" % coach.rules.size())
	check("rule facts: opponent state names", CoachController._opponent_state(p2) in CoachController.OPPONENT_STATES)
	check("rule matching: health_below and range", CoachController._rule_matches({range = "close", health_below = 0.5}, {range = "close", health = 0.4})
		and not CoachController._rule_matches({range = "close", health_below = 0.5}, {range = "close", health = 0.6})
		and not CoachController._rule_matches({opponent = "idle"}, {opponent = "jumping"}))
	# standing close with the dummy idle: the "sweep" rule (close) should fire and the sweep come out
	coach.queued.clear()
	coach.rules = coach.rules.filter(func(r: Dictionary) -> bool: return r.name == "sweep")
	coach.apply_plan({aggression = 0.0, options = {wait = 3.0}})
	p1.position.x = p2.position.x - 0.9
	p1.reset_physics_interpolation()
	var rule_fired := false
	for i in 120:
		step()
		if coach.last_rule == "sweep":
			rule_fired = true
			break
	check("a matching rule fires and names itself", rule_fired, coach.last_rule)
	coach.rules.clear()
	step(60)

	# round summary tallies the attacks
	var summary := link.round_summary()
	var p1_attacks: Dictionary = summary.p1.attacks
	check("round summary counts p1's sweeps", p1_attacks.has("2HK") and int(p1_attacks["2HK"].hit) + int(p1_attacks["2HK"].blocked) + int(p1_attacks["2HK"].whiffed) + int(p1_attacks["2HK"].counter) >= 2, str(p1_attacks))
	check("round summary has health left", summary.p2.health_left < summary.p2.max_health)

	# policy frame applies plan and rules together
	link._handle({type = "policy", side = "p1", plan_id = "pol-1", plan = {aggression = 0.4}, rules = [{name = "r", when = {range = "far"}, do = ["approach 20"]}]})
	check("policy frame applies plan and rules", is_equal_approx(coach.aggression, 0.4) and coach.rules.size() == 1 and link.sent[-1].type == "applied" and link.sent[-1].ok)

	# captions
	coach.set_caption("  Keep him at kick range, punish the step in with the spinning back kick!  ")
	check("captions are trimmed to 60 characters", coach.caption.length() == 60, coach.caption)

	# watchability: plan chips, queue chips, corner talk, reads
	var chips := CoachLink.plan_chips({aggression = 0.5, range = "mid", options = {throw = 1.0}}, {aggression = 0.9, range = "close", block = 0.95, options = {throw = 2.0, poke = 1.0}})
	check("plan chips name what changed with arrows", ", ".join(chips) == "aggression ↑ 0.9, range → close, block → 0.95, throw ↑ 2", ", ".join(chips))
	check("plan chips are capped", CoachLink.plan_chips({}, {aggression = 0.1, block = 0.2, punish = 0.3, anti_air = 0.4, pressure = 0.5}).size() == CoachLink.MAX_CHIPS)
	var reflex_chips := CoachLink.plan_chips({block = 0.5}, {block = 0.75, range = "close"}, CoachLink.REFLEX_MARK)
	check("the reflexes' nudges carry the bolt", ", ".join(reflex_chips) == "⚡ block ↑ 0.75, ⚡ range → close", ", ".join(reflex_chips))
	check("a queued super is called out", CoachLink.queue_chip(["block 12", "236236K"]) == "SUPER QUEUED · block 12 › 236236K" and CoachLink.queue_chip(["2HK"]) == "QUEUE · 2HK")
	var sent_before := link.sent.size()
	link._handle({type = "talk", side = "p1", text = "They keep whiffing; blocking more."})
	check("a talk frame is accepted offline and answers nothing", link.sent.size() == sent_before)
	var bad_read := link.set_prediction(0, "moonwalk", "r-0")
	check("an unknown read is refused", bad_read.size() == 1 and bad_read[0].begins_with("unknown read moonwalk"), ", ".join(bad_read))
	var ok_read := link.set_prediction(0, "2hk", "r-1")
	check("a read may name an opponent move in any case", ok_read.is_empty() and link._predictions[0].what == "2HK", str(link._predictions[0]))
	link.set_prediction(0, "reversal", "r-2")
	var replaced: Dictionary = link.sent[-1]
	check("a replaced read counts as a miss", replaced.type == "event" and replaced.event == "read" and replaced.right == false and replaced.actual == "replaced" and link.round_summary().p1.reads.made == 2, str(replaced))
	var dragon: MoveData = p2.data.moves.filter(func(mv: MoveData) -> bool: return mv.input == "623P")[0]
	check("read matching: words and inputs", CoachLink.read_matches("reversal", "", dragon) and CoachLink.read_matches("623p", "", dragon) and not CoachLink.read_matches("low", "", dragon) and CoachLink.read_matches("jump", "jump", null) and not CoachLink.read_matches("throw", "jump", null))
	link._on_attack_started(dragon, 1)
	var called: Dictionary = link.sent[-1]
	check("the opponent's dragon fulfils the reversal read", called.event == "read" and called.right == true and called.actual == dragon.name and link._predictions[0].is_empty(), str(called))
	link.set_prediction(1, "jump", "r-3")
	link._ticks += CoachLink.PREDICT_TICKS
	link._on_ticked()
	var expired: Dictionary = link.sent.filter(func(f: Dictionary) -> bool: return f.type == "event" and f.event == "read" and f.side == "p2")[-1]
	check("a read that does not come true expires as a miss", expired.right == false and link._predictions[1].is_empty(), str(expired))
	var totals: Dictionary = link.round_summary().p1
	check("round summary carries reads, supers and totals", totals.reads.right == 1 and totals.reads.made == 2 and totals.has("supers") and totals.totals.has("whiffed"), str(totals.reads))

	print("\n%d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
