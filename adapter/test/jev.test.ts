import assert from "node:assert/strict";
import { test } from "node:test";
import { choiceOf, defaultJevModel, DO_JEV_URL, FakeJevClient, favourWeights, GATES, JevClient, jevModelId, jevQuestions, jevState, KNOBS, knobOf, LEVELS, NO_READ, noulOf, parseRecent, JEV_MODEL } from "../src/jev.ts";
import { READ_WORDS } from "../src/prompt.ts";
import { parseSpec } from "../src/reflex.ts";
import { OPTION_NAMES } from "../src/types.ts";
import { hello, state } from "./helpers.ts";

test("the question set: five knobs on the levels, three choices, the read over the opponent's specials, three gates", () => {
  const q = jevQuestions("p1", hello);
  for (const k of KNOBS) assert.deepEqual(q[k].type === "score" ? q[k].criteria : null, LEVELS);
  assert.deepEqual(Object.keys(q.range.type === "choice" ? q.range.criteria : {}), ["close", "mid", "far"]);
  assert.deepEqual(Object.keys(q.reaction.type === "choice" ? q.reaction.criteria : {}), ["fast", "normal", "slow"]);
  const favour = Object.keys(q.favour.type === "choice" ? q.favour.criteria : {});
  for (const o of OPTION_NAMES) assert.ok(favour.includes(o), o);
  assert.ok(favour.includes("none"));
  const reads = q.read.type === "choice" ? q.read.criteria : {};
  assert.ok(reads["236P"]?.includes("Fireball"), "the opponent's specials are read options");
  assert.ok(reads["623P"]?.includes("invincible"));
  for (const w of READ_WORDS) assert.ok(w in reads, w);
  assert.ok(NO_READ in reads);
  for (const g of GATES) assert.equal(q[g].type, "noul");
  assert.equal(Object.keys(q).length, 12);
  // The other side reads Jin's specials, not Kenji's.
  const q2 = jevQuestions("p2", hello);
  assert.ok("623K" in (q2.read.type === "choice" ? q2.read.criteria : {}));
  assert.ok(!("236P" in (q2.read.type === "choice" ? q2.read.criteria : {})));
});

test("the state block names both fighters, carries the turn's words, the baseline and the orders, and stays small", () => {
  const s = jevState("p1", hello, state(), [{ type: "event", tick: 1, event: "hit", attacker: "p2", defender: "p1", input: "2LK", result: "hit", damage: 37 }], { block: 0.5, range: "mid" }, "Watch the fireball; punish it.");
  assert.match(s, /^Fighter: Jin \(Kicker\)\. Opponent: Kenji \(Zoner\); their specials: 236P Fireball \(projectile\), 623P Rising Uppercut/);
  assert.match(s, /Round 1, 89 s left/);
  assert.match(s, /Since your last turn: they landed 2LK/);
  assert.match(s, /Coach's baseline plan: block 0.5; range mid\./);
  assert.match(s, /Coach's standing orders: Watch the fireball; punish it\./);
  assert.ok(!s.includes("Adjust the plan with the tools"));
  assert.ok(s.length < 1500, `${s.length} chars`);
  assert.match(jevState("p1", hello, null, [], null, null), /Coach's baseline plan: the fighter's own default style\.\nCoach's standing orders: none yet\./);
});

test("answers map to knob levels, choices with a probability, and gate probabilities", () => {
  assert.equal(knobOf({ type: "score", score: 2.6 }), 0.75);
  assert.equal(knobOf({ type: "score", score: 0.2 }), 0);
  assert.equal(knobOf({ type: "score", score: 9 }), 1);
  assert.equal(knobOf({ type: "score", probabilities: [0, 0, 0.1, 0.8, 0.1] }), 0.75);
  assert.equal(knobOf({ type: "score", probabilities: { 0: 0.9, 1: 0.1 } }), 0);
  assert.equal(knobOf(undefined), null);
  assert.equal(knobOf({ type: "score" }), null);
  assert.deepEqual(choiceOf({ type: "choice", choice: "close", probabilities: { close: 0.7, mid: 0.2, far: 0.1 } }), { choice: "close", p: 0.7 });
  assert.deepEqual(choiceOf({ type: "choice", probabilities: { close: 0.2, mid: 0.5, far: 0.3 } }), { choice: "mid", p: 0.5 });
  assert.deepEqual(choiceOf({ type: "choice", choice: "far", confidence: 0.55 }), { choice: "far", p: 0.55 });
  assert.equal(choiceOf(undefined), null);
  assert.equal(noulOf({ type: "noul", noul: 0.83 }), 0.83);
  assert.equal(noulOf({ type: "noul", noul: 1.4 }), 1);
  assert.equal(noulOf({ type: "noul" }), null);
});

test("parseRecent reads inputs and outcomes from the attack list", () => {
  assert.deepEqual(parseRecent("236P Fireball (blocked), 2LK (hit), j.HK Flying Kick (whiffed), HP Straight (pending)"), [
    { input: "236P", outcome: "blocked" },
    { input: "2LK", outcome: "hit" },
    { input: "j.HK", outcome: "whiffed" },
    { input: "HP", outcome: "pending" },
  ]);
});

test("the fake Jev answers from the state's words: close against a zoner, a read on a repeated attack, gates on health and the super", async () => {
  const fake = new FakeJevClient();
  const q = jevQuestions("p1", hello);
  const r = await fake.decide("jev:fake", jevState("p1", hello, state(), [], null, null), q);
  assert.deepEqual(Object.keys(r.answers), Object.keys(q));
  assert.equal(choiceOf(r.answers.range)?.choice, "close");
  assert.equal(choiceOf(r.answers.read)?.choice, NO_READ, "one fireball is not a pattern");
  assert.equal(knobOf(r.answers.aggression), 0.75, "behind on health: more aggression");
  assert.equal(knobOf(r.answers.block), 0.25);
  assert.equal(noulOf(r.answers.plan_failing), 0.8, "75% against 100%: the plan is failing");
  assert.equal(noulOf(r.answers.window_open), 0.85, "the super is ready in range");
  assert.equal(noulOf(r.answers.pattern_changed), 0.2);
  assert.ok(r.usage.input_tokens > 200);
  assert.equal(r.usd, 0);
  // Two fireballs and two hits: a read on 236P, block and reaction up.
  const s2 = state({ p2: { ...state().p2, recent: [{ input: "236P", outcome: "blocked" }, { input: "236P", outcome: "hit" }, { input: "2LK", outcome: "hit" }] } });
  const r2 = await fake.decide("jev:fake", jevState("p1", hello, s2, [], null, null), q);
  assert.deepEqual(choiceOf(r2.answers.read), { choice: "236P", p: 0.72 });
  assert.equal(knobOf(r2.answers.block), 0.75);
  assert.equal(choiceOf(r2.answers.reaction)?.choice, "fast");
  assert.equal(fake.calls, 2);
  // An override wins.
  const forced = new FakeJevClient(0, () => ({ read: { type: "choice", choice: "jump", probabilities: { jump: 0.9 } } }));
  const r3 = await forced.decide("jev:fake", jevState("p1", hello, state(), [], null, null), q);
  assert.deepEqual(choiceOf(r3.answers.read), { choice: "jump", p: 0.9 });
});

test("favourWeights raises the new favourite and puts the old one back", () => {
  assert.deepEqual(favourWeights(null, "throw"), { throw: 2 });
  assert.deepEqual(favourWeights("throw", "poke"), { throw: 1, poke: 2 });
  assert.deepEqual(favourWeights("poke", "none"), { poke: 1 });
  assert.deepEqual(favourWeights("none", "none"), {});
});

test("parseSpec: a brain, a brain with reflexes, reflexes alone; a fake brain fakes its reflexes", () => {
  assert.deepEqual(parseSpec("anthropic:claude-opus-5-5"), { brain: "anthropic:claude-opus-5-5", reflex: null });
  assert.deepEqual(parseSpec("anthropic:claude-opus-5-5+jev"), { brain: "anthropic:claude-opus-5-5", reflex: "jev:jev" });
  assert.deepEqual(parseSpec("openai:gpt-5.4-mini+fake"), { brain: "openai:gpt-5.4-mini", reflex: "jev:fake" });
  assert.deepEqual(parseSpec("fake:coach+jev"), { brain: "fake:coach", reflex: "jev:fake" });
  assert.deepEqual(parseSpec("jev:jev"), { brain: null, reflex: "jev:jev" });
  assert.deepEqual(parseSpec("jev:typesafe-jev-1.13.0"), { brain: null, reflex: "jev:typesafe-jev-1.13.0" });
  assert.deepEqual(parseSpec("jev:fake"), { brain: null, reflex: "jev:fake" });
  assert.throws(() => parseSpec("fake:coach+turbo"), /\+jev/);
  assert.equal(jevModelId("jev:jev"), JEV_MODEL);
  assert.equal(jevModelId("jev:typesafe-jev-2"), "typesafe-jev-2");
});

test("the default model id follows the endpoint: DigitalOcean names the version, TypeSafe takes jev-latest, $JEV_MODEL wins", () => {
  assert.equal(defaultJevModel(DO_JEV_URL), "typesafe-jev-1.13.0");
  assert.equal(defaultJevModel("https://api.typesafe.ai/v1/systemone"), "jev-latest");
  assert.equal(defaultJevModel("https://api.typesafe.ai:443/v1/systemone"), "jev-latest");
  assert.equal(defaultJevModel("https://proxy.example.test/typesafe/v1/systemone"), "typesafe-jev-1.13.0", "a gateway keeps the versioned id");
  assert.equal(defaultJevModel("not a url"), "typesafe-jev-1.13.0");
  assert.equal(defaultJevModel("https://api.typesafe.ai/v1/systemone", "jev-1.14.0"), "jev-1.14.0");
});

test("JevClient posts state and questions with the key and reads the answers back; no key is an error", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchFn = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ model: JEV_MODEL, answers: { read: { type: "choice", choice: "236P", probabilities: { "236P": 0.8 }, confidence: 0.8 } }, usage: { input_tokens: 1200, output_tokens: 0 } }), { status: 200 });
  }) as typeof fetch;
  let key = "";
  const client = new JevClient(fetchFn, "https://example.test/v1/systemone", () => ({ key }));
  {
    await assert.rejects(client.decide("jev:jev", "state", {}), /no Jev key/);
    key = "test-key-1234";
    const r = await client.decide("jev:jev", "the state", { read: { type: "noul", instructions: "x" } });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://example.test/v1/systemone");
    assert.equal((calls[0].init.headers as Record<string, string>).authorization, "Bearer test-key-1234");
    assert.deepEqual(JSON.parse(String(calls[0].init.body)), { model: JEV_MODEL, state: "the state", questions: { read: { type: "noul", instructions: "x" } } });
    assert.deepEqual(choiceOf(r.answers.read), { choice: "236P", p: 0.8 });
    assert.equal(r.usage.input_tokens, 1200);
    assert.ok(r.usd != null && Math.abs(r.usd - (1200 * 0.042) / 1e6) < 1e-12, `usd ${r.usd}`);
  }
  // The real client reads the key file or $JEV_API_KEY (models.ts providerKey): not exercised here, so the machine's key stays out of the test.
});
