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

	# captions
	coach.set_caption("  Keep him at kick range, punish the step in with the spinning back kick!  ")
	check("captions are trimmed to 60 characters", coach.caption.length() == 60, coach.caption)

	print("\n%d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
