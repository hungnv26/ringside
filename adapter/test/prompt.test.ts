import assert from "node:assert/strict";
import { test } from "node:test";
import { TOOLS, buildSystemPrompt, buildTurnMessage, mergePlan, planText, validatePlan, validateQueue, validateSay } from "../src/prompt.ts";
import { hello, state } from "./helpers.ts";

test("system prompt names the fighter, its moves and the opponent's specials", () => {
  const s = buildSystemPrompt("p1", hello);
  assert.match(s, /coach of Jin/);
  assert.match(s, /best of 3 rounds of 99 seconds, 980 health/);
  assert.match(s, /- 236K: Spinning Back Kick, mid, 14f startup, 110 damage, travels/);
  assert.match(s, /Opponent: Kenji \(Zoner\), 1000 health\. Their specials: 236P Fireball, 623P Rising Uppercut/);
  const s2 = buildSystemPrompt("p2", hello);
  assert.match(s2, /coach of Kenji/);
  assert.match(s2, /Opponent: Jin/);
});

test("turn message reads the state from the side's point of view", () => {
  const m = buildTurnMessage("p1", state(), [], null, []);
  assert.equal(
    m,
    [
      "Round 1, 89 s left, rounds won you 0 - 0 them. Distance 1.7 m.",
      "You: health 75%, meter 100% (SUPER READY), idle. Recent attacks: HK Roundhouse (whiffed), 2LK (hit).",
      "Opponent: health 100%, meter 20%, attack (236P), cornered. Recent attacks: 236P Fireball (blocked).",
      "Since your last turn: nothing notable.",
      "Your current plan: the fighter's own default style.",
      "Adjust the plan with the tools.",
    ].join("\n"),
  );
  const m2 = buildTurnMessage("p2", state({ wins: [1, 0] }), [], null, []);
  assert.match(m2, /rounds won you 0 - 1 them/);
  assert.match(m2, /^You: health 100%/m);
});

test("turn message tells events, the plan in force and the last results", () => {
  const events = [
    { type: "event" as const, tick: 1, event: "round_start", round: 2 },
    { type: "event" as const, tick: 2, event: "hit", attacker: "p2", defender: "p1", input: "236P", name: "Fireball", result: "hit", damage: 70, combo: 1 },
    { type: "event" as const, tick: 3, event: "knockdown", side: "p1" },
    { type: "event" as const, tick: 4, event: "round_end", winner: "p2", reason: "K.O." },
  ];
  const m = buildTurnMessage("p1", null, events, { aggression: 0.8, range: "close", options: { poke: 2 } }, ["set_plan {\"aggression\":0.8}: applied"]);
  assert.match(m, /^The round has not started yet\./);
  assert.match(m, /Round 2 starts\. they landed 236P Fireball \(hit, 70 damage\) on you\. you got knocked down\. Round over: they won it \(K\.O\.\)\./);
  assert.match(m, /Your current plan: aggression 0\.8; range close; options poke 2\./);
  assert.match(m, /Your last tools: set_plan \{"aggression":0\.8\}: applied\./);
});

test("tools are set_plan, queue and say", () => {
  assert.deepEqual(
    TOOLS.map((t) => t.function.name),
    ["set_plan", "queue", "say", "predict"],
  );
  const props = (TOOLS[0].function.parameters as { properties: Record<string, unknown> }).properties;
  assert.deepEqual(Object.keys(props), ["aggression", "range", "block", "punish", "anti_air", "reaction", "pressure", "options"]);
});

test("validatePlan clamps numbers and drops what it does not know", () => {
  const { plan, problems } = validatePlan({ aggression: 1.7, block: -1, range: "mid", reaction: "fast", options: { poke: 9, bogus: 1, dash: "x" }, foo: 1 });
  assert.deepEqual(plan, { aggression: 1, block: 0, range: "mid", reaction: "fast", options: { poke: 3 } });
  assert.deepEqual(problems, ["unknown option bogus", "option dash must be a number", "unknown field foo"]);
  assert.deepEqual(validatePlan({ range: 9 }).plan, { range: 4 });
  assert.deepEqual(validatePlan({ range: "near" }).problems, ["range must be close, mid, far or metres"]);
  assert.deepEqual(validatePlan("x").problems, ["set_plan needs an object"]);
});

test("validateQueue keeps four strings; validateSay trims to 60", () => {
  assert.deepEqual(validateQueue({ moves: ["2HK", " 236K ", 3, "", "LP", "HP", "HK"] }), { moves: ["2HK", "236K", "LP", "HP"], problems: ["only the first 4 moves are queued"] });
  assert.deepEqual(validateQueue({}), { moves: [], problems: ["queue needs moves: [..]"] });
  assert.equal(validateSay({ text: "  Keep   your\n distance " + "x".repeat(80) }).length, 60);
  assert.equal(validateSay({ text: " Go low. " }), "Go low.");
});

test("mergePlan keeps earlier fields and merges options", () => {
  const merged = mergePlan({ aggression: 0.5, options: { poke: 2 } }, { range: "far", options: { dash: 0 } });
  assert.deepEqual(merged, { aggression: 0.5, range: "far", options: { poke: 2, dash: 0 } });
  assert.equal(planText(null), "the fighter's own default style");
});
