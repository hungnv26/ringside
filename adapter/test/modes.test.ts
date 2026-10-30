import assert from "node:assert/strict";
import { test } from "node:test";
import { Coach } from "../src/coach.ts";
import { FakeModelClient } from "../src/fake.ts";
import { buildScriptTurnMessage, SCRIPT_TOOLS, summaryText, validateRules } from "../src/prompt.ts";
import { FakeLink, hello, state as makeState, settle } from "./helpers.ts";

test("validateRules keeps good rules, clamps weights and drops bad conditions", () => {
  const { rules, problems } = validateRules([
    { name: "punish", when: { range: "close", opponent: "recovering" }, do: ["2HP"], weight: 9 },
    { when: { range: "orbit", meter_full: "yes" }, do: ["LP"] },
    { name: "empty", when: {}, do: [] },
    "not a rule",
  ]);
  assert.equal(rules.length, 2);
  assert.equal(rules[0].weight, 5);
  assert.deepEqual(rules[1].when, {});
  assert.equal(rules[1].name, "rule 2");
  assert.ok(problems.some((p) => p.includes("range")) && problems.some((p) => p.includes("meter_full")));
  assert.ok(problems.some((p) => p.includes("no moves")) && problems.some((p) => p.includes("not an object")));
  assert.equal(validateRules(Array.from({ length: 14 }, (_, i) => ({ when: {}, do: ["LP"], name: `r${i}` }))).rules.length, 12);
});

test("the script turn message carries the round summary in words", () => {
  const h = hello;
  const first = buildScriptTurnMessage("p1", h, [], []);
  assert.match(first, /about to start/);
  const summary = { p1: { attacks: { "2HK": { hit: 2, counter: 0, blocked: 1, whiffed: 3 } }, throws: 1, knockdowns: 0, health_left: 500, max_health: 1000 }, p2: { attacks: {}, throws: 0, knockdowns: 2, health_left: 0, max_health: 1000, rule_fired_last: "" } };
  const after = buildScriptTurnMessage("p2", h, [{ type: "event", tick: 1, event: "round_end", round: 1, winner: "p1", reason: "K.O.", summary }], ["set_policy 3 rules: applied"]);
  assert.match(after, /Round 1 over: they won it \(K\.O\.\)/);
  assert.match(after, /Opponent: health left 50%, 1 throws, knocked down 0 times\. Attacks: 2HK 2 hit, 0 counter, 1 blocked, 3 whiffed/);
  assert.match(after, /You: health left 0%/);
  assert.match(summaryText("p1", null), /no summary/);
});

test("the script tools are set_policy and say", () => {
  assert.deepEqual(SCRIPT_TOOLS.map((t) => t.function.name), ["set_policy", "say"]);
});

test("script mode: a policy before the match and after each round, none during it", async () => {
  const link = new FakeLink();
  const c = new Coach("p1", "fake:coach", new FakeModelClient(), link, hello, null, { mode: "script" });
  await settle();
  assert.equal(c.turns, 1);
  const policy = link.sent.find((f) => f.type === "policy") as unknown as { rules: unknown[]; plan: unknown; plan_id: string };
  assert.ok(policy && Array.isArray(policy.rules) && policy.rules.length >= 3);
  assert.equal(policy.plan_id, "p1-1-0");
  assert.ok(c.rules && c.rules.length >= 3);
  link.feedEvent("round_start", { round: 1 });
  link.feedState(makeState());
  await settle();
  assert.equal(c.turns, 1, "no turn during the round");
  link.feedApplied("p1", "p1-1-0", true);
  link.feedEvent("round_end", { round: 1, winner: "p2", reason: "K.O.", summary: { p1: { attacks: {} }, p2: { attacks: {} } } });
  await settle();
  assert.equal(c.turns, 2);
  assert.equal(link.sent.filter((f) => f.type === "policy").length, 2);
  c.stop();
});
