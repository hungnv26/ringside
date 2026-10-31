import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Coach } from "../src/coach.ts";
import { FakeModelClient } from "../src/fake.ts";
import { FakeJevClient, type JevResult, type ReflexClient } from "../src/jev.ts";
import { BattleLog } from "../src/log.ts";
import { Reflexes, type ReadLedger } from "../src/reflex.ts";
import type { ChatBody, ChatResult, ModelClient, PlanFrame, PredictFrame, SayFrame } from "../src/types.ts";
import { FakeClock, FakeLink, hello, settle, state } from "./helpers.ts";

/** A brain the tests can inspect without a model: the plan it set, when, and the turns asked of it. */
function brain(over: Partial<{ plan: Record<string, unknown>; orders: string | null; planSetAt: number }> = {}) {
  const turns: string[] = [];
  const b = { plan: null as Record<string, unknown> | null, orders: null as string | null, planSetAt: -Infinity, turns, turn: (reason: string) => turns.push(reason), ...over };
  return b as unknown as Coach & { turns: string[] };
}

function reflexes(link: FakeLink, clock: FakeClock, client: ReflexClient = new FakeJevClient(), opts: Record<string, unknown> = {}): Reflexes {
  return new Reflexes("p1", "jev:fake", client, link, hello, null, { now: clock.now, hz: 4, ...opts }); // 4 Hz: these tests tick on every frame
}

const plans = (link: FakeLink) => link.sent.filter((f): f is PlanFrame => f.type === "plan");
const predicts = (link: FakeLink) => link.sent.filter((f): f is PredictFrame => f.type === "predict");
const says = (link: FakeLink) => link.sent.filter((f): f is SayFrame => f.type === "say");

test("reflexes tick on state frames while the round is live, at most four times a second, never two at once", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const r = reflexes(link, clock);
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 0, "no round yet");
  link.feedEvent("round_start", { round: 1 });
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 1);
  clock.t = 100;
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 1, "too soon");
  assert.equal(r.skipped, 1);
  clock.t = 250;
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 2);
  link.feedEvent("round_end", { winner: "p2", reason: "K.O." });
  clock.t = 1000;
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 2, "between rounds");
  assert.equal(r.status, "ticking");
  // At 2 a second every other frame goes.
  const link2 = new FakeLink();
  const r2 = reflexes(link2, clock, new FakeJevClient(), { hz: 2 });
  link2.feedEvent("round_start", { round: 1 });
  for (const t of [1000, 1250, 1500, 1750]) {
    clock.t = t;
    link2.feedState(state());
    await settle();
  }
  assert.equal(r2.ticks, 2);
});

test("a slow decision holds the next tick: one call in flight", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  let release: (() => void) | null = null;
  const slow: ReflexClient = {
    decide: async (spec, s, q) => {
      await new Promise<void>((res) => (release = res));
      return new FakeJevClient().decide(spec, s, q);
    },
  };
  const r = reflexes(link, clock, slow);
  link.feedEvent("round_start", { round: 1 });
  link.feedState(state());
  await settle();
  clock.t = 500;
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 1);
  assert.equal(r.skipped, 1);
  release!();
  await settle();
  assert.equal(plans(link).length, 1);
});

test("the first tick sets the knobs from Jev's levels; a read goes when confident and waits for the game's answer", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const ledger: ReadLedger = { owner: null };
  const r = reflexes(link, clock, new FakeJevClient(), { ledger });
  link.feedEvent("round_start", { round: 1 });
  const s2 = state({ p2: { ...state().p2, recent: [{ input: "236P", outcome: "blocked" }, { input: "236P", outcome: "hit" }] } });
  link.feedState(s2);
  await settle();
  const [plan] = plans(link);
  assert.deepEqual(plan.plan, { aggression: 0.75, block: 0.25, punish: 0.5, anti_air: 0.25, pressure: 0.5 });
  assert.equal(plan.source, "reflex");
  assert.equal(plan.plan_id, "p1-r1");
  assert.deepEqual(r.applied, plan.plan);
  assert.equal(predicts(link).length, 1);
  assert.equal(predicts(link)[0].what, "236P");
  assert.equal(ledger.owner, "reflex");
  assert.equal(r.reads.made, 1);
  // The same state again: nothing to nudge, no second read while one is pending.
  clock.t = 250;
  link.feedState(s2);
  await settle();
  assert.equal(plans(link).length, 1);
  assert.equal(predicts(link).length, 1);
  // The game resolves it: counted, and a new read may go.
  link.feedEvent("read", { side: "p1", what: "236P", right: true, actual: "Fireball" });
  assert.deepEqual(r.reads, { made: 1, right: 1 });
  assert.equal(ledger.owner, null);
  clock.t = 500;
  link.feedState(s2);
  await settle();
  assert.equal(predicts(link).length, 2);
  // A read the other side made is not ours.
  link.feedEvent("read", { side: "p2", what: "623K", right: true, actual: "Tornado Kick" });
  assert.equal(r.reads.right, 1);
});

test("a read under the threshold stays home; the threshold is a setting", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const s2 = state({ p2: { ...state().p2, recent: [{ input: "236P", outcome: "blocked" }, { input: "236P", outcome: "hit" }] } });
  reflexes(link, clock, new FakeJevClient(), { readThreshold: 0.8 });
  link.feedEvent("round_start", { round: 1 });
  link.feedState(s2);
  await settle();
  assert.equal(predicts(link).length, 0, "0.72 is under 0.8");
});

test("range, reaction and the favoured option change only when three ticks agree", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const r = reflexes(link, clock);
  link.feedEvent("round_start", { round: 1 });
  const close = state({ distance: 0.9 }); // Kenji is a zoner: close; under 1.2 m: favour the throw
  for (const t of [0, 250, 500]) {
    clock.t = t;
    link.feedState(close);
    await settle();
  }
  const all = plans(link);
  assert.equal(all.length, 2, "the knobs on tick 1, the choices on tick 3");
  assert.deepEqual(all[1].plan, { range: "close", reaction: "normal", options: { throw: 2 } });
  assert.deepEqual(r.applied.options, { throw: 2 });
  // Back to mid range: the favourite goes back to normal when three ticks agree on none.
  for (const t of [750, 1000, 1250]) {
    clock.t = t;
    link.feedState(state({ distance: 1.7 }));
    await settle();
  }
  const last = plans(link).at(-1)!;
  assert.deepEqual(last.plan, { options: { throw: 1 } });
});

test("with a brain: nudges stay within a quarter of its plan, wait 2 s after it sets one, and the gates wake it with a cooldown", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  clock.t = 10_000;
  const b = brain({ plan: { block: 0.5, aggression: 0.25 }, planSetAt: 9_000 });
  const r = reflexes(link, clock, new FakeJevClient(), { coach: b });
  link.feedEvent("round_start", { round: 1 });
  link.feedState(state());
  await settle();
  assert.equal(plans(link).length, 0, "the brain set its plan 1 s ago");
  assert.deepEqual(b.turns, ["reflex:plan_failing+window_open"], "one turn for the gates that fire together");
  assert.deepEqual(r.gates, { plan_failing: 1, window_open: 1, pattern_changed: 0 });
  clock.t = 11_500;
  link.feedState(state());
  await settle();
  const [plan] = plans(link);
  // aggression: Jev says 0.75, the brain's 0.25 allows up to 0.5; block: Jev says 0.25, the brain's 0.5 allows down to 0.25.
  assert.deepEqual(plan.plan, { aggression: 0.5, block: 0.25, punish: 0.5, anti_air: 0.25, pressure: 0.5 });
  assert.equal(b.turns.length, 1, "the gates rest 4 s");
  clock.t = 14_100;
  link.feedState(state());
  await settle();
  assert.equal(b.turns.length, 2);
  assert.equal(says(link).length, 0, "with a brain the reflexes do not caption");
  assert.match(r.recordForBrain() ?? "", /^Your reflexes since your last turn: 3 ticks; reads 0\/0; gates plan failing 2×, window open 2×; nudged push ↑, block ↓, punish 0\.5, anti-air 0\.25, pressure 0\.5, close in, react normal\./, "the majorities kept counting through the hold");
  assert.equal(r.recordForBrain(), null, "the record resets");
  // A plan the brain sets afresh is the new baseline and holds the reflexes off again.
  b.plan = { aggression: 1, block: 0.5 };
  b.planSetAt = clock.t;
  const before = plans(link).length;
  clock.t = 14_400;
  link.feedState(state());
  await settle();
  assert.equal(plans(link).length, before, "held: nothing sent");
});

test("gates are only recorded when the brain is not to be woken (self-coding mode), and no plan nudges go", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const b = brain();
  const r = reflexes(link, clock, new FakeJevClient(), { coach: b, nudgePlan: false, wakeBrain: false });
  link.feedEvent("round_start", { round: 1 });
  link.feedState(state());
  await settle();
  assert.equal(plans(link).length, 0);
  assert.deepEqual(b.turns, []);
  assert.deepEqual(r.gates, { plan_failing: 1, window_open: 1, pattern_changed: 0 });
});

test("without a brain the reflexes caption their own changes, at most every 2 s", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const r = reflexes(link, clock);
  link.feedEvent("round_start", { round: 1 });
  const s2 = state({ p2: { ...state().p2, recent: [{ input: "236P", outcome: "blocked" }, { input: "236P", outcome: "hit" }] } });
  link.feedState(s2);
  await settle();
  assert.equal(says(link).length, 1);
  assert.equal(says(link)[0].text, "push 0.75, block 0.25, punish 0.5, anti-air 0.25");
  assert.equal(r.lastCaption, says(link)[0].text);
  clock.t = 250;
  link.feedState(state({ p2: { ...state().p2, recent: [{ input: "j.HK", outcome: "hit" }, { input: "j.HK", outcome: "hit" }] } }));
  await settle();
  assert.equal(plans(link).length, 2, "anti-air and block went up");
  assert.equal(says(link).length, 1, "too soon for another caption");
  clock.t = 2300;
  link.feedState(s2);
  await settle();
  assert.equal(says(link).length, 2);
});

test("the budget, errors and the log", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const dear: ReflexClient = { decide: async (spec, s, q) => ({ ...(await new FakeJevClient().decide(spec, s, q)), usd: 0.01 }) };
  const dir = mkdtempSync(join(tmpdir(), "ringside-reflex-"));
  const log = BattleLog.at(join(dir, "match"));
  const r = new Reflexes("p1", "jev:fake", dear, link, hello, log, { now: clock.now, hz: 4, capUsd: 0.015 });
  link.feedEvent("round_start", { round: 1 });
  link.feedState(state());
  await settle();
  clock.t = 250;
  link.feedState(state());
  await settle();
  assert.equal(r.status, "out of budget");
  assert.equal(r.usd, 0.02);
  clock.t = 500;
  link.feedState(state());
  await settle();
  assert.equal(r.ticks, 2);
  const lines = readFileSync(join(dir, "match", "p1.reflex.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
  assert.equal(lines.length, 2);
  assert.equal(lines[0].tick, 1);
  assert.ok(lines[0].sent[0].startsWith("plan {"));
  assert.deepEqual(lines[0].gates, ["plan_failing", "window_open"]);
  assert.equal(lines[0].last.range, "close");
  assert.ok(readFileSync(join(dir, "match", "p1.md"), "utf8").includes("Reflexes only (jev:fake)"), "a corner with no brain writes the questions as its system text");
  // Errors: five in a row with no good answer is failed.
  const broken: ReflexClient = { decide: async () => { throw new Error("jev 503: busy"); } };
  const link2 = new FakeLink();
  const r2 = reflexes(link2, clock, broken);
  link2.feedEvent("round_start", { round: 1 });
  for (let i = 0; i < 5; i++) {
    clock.t = 10_000 + i * 250;
    link2.feedState(state());
    await settle();
  }
  assert.equal(r2.errors, 5);
  assert.equal(r2.lastError, "jev 503: busy");
  assert.equal(r2.status, "failed");
});

test("a brain with reflexes: the orders tool, the reflex record in its prompt, the read ledger, no cadence", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const ledger: ReadLedger = { owner: null };
  const prompts: string[] = [];
  let tools: string[] = [];
  const client: ModelClient = {
    chat: async (spec: string, body: ChatBody): Promise<ChatResult> => {
      prompts.push(String(body.messages[1].content));
      tools = (body.tools ?? []).map((t) => t.function.name);
      const base = await new FakeModelClient().chat(spec, body);
      base.message.tool_calls = [
        ...(base.message.tool_calls ?? []),
        { id: "o", type: "function", function: { name: "orders", arguments: JSON.stringify({ text: "Watch the fireball; punish every whiff." }) } },
        { id: "p", type: "function", function: { name: "predict", arguments: JSON.stringify({ what: "jump" }) } },
      ];
      return base;
    },
  };
  const coach = new Coach("p1", "fake:coach", client, link, hello, null, { cadenceMs: 0, capUsd: 1, now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer, reflexes: true, ledger, extraContext: () => r.recordForBrain() });
  const r = reflexes(link, clock, new FakeJevClient(), { coach, ledger });
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  assert.equal(coach.turns, 1);
  assert.ok(tools.includes("orders"));
  assert.equal(coach.orders, "Watch the fireball; punish every whiff.");
  assert.equal(coach.stats().orders, coach.orders);
  assert.equal(ledger.owner, "coach");
  assert.ok(coach.planSetAt === 0);
  await clock.advance(5000);
  assert.equal(coach.turns, 1, "cadence 0: no turn by the clock");
  // A reflex tick after the brain's hold: it sees the orders, nudges within the band, and wakes the brain.
  clock.t = 2500;
  link.feedState(state());
  await settle();
  assert.equal(coach.turns, 2, "woken by a gate");
  assert.match(prompts[1], /Your reflexes since your last turn: 1 ticks; reads 0\/0; gates plan failing 1×, window open 1×; nudged .*\nAdjust the plan with the tools\.$/);
  const nudge = plans(link).find((f) => f.source === "reflex")!;
  assert.equal(nudge.plan.aggression, 0.55, "the brain's 0.3 allows up to 0.55; Jev's 0.75 is clamped to the band");
  // The brain's own read: a replacement miss counts for nobody, the resolution for the brain.
  link.feedEvent("read", { side: "p1", what: "jump", right: false, actual: "replaced" });
  assert.deepEqual(coach.reads, { made: 2, right: 0 });
  link.feedEvent("read", { side: "p1", what: "jump", right: true, actual: "jump" });
  assert.deepEqual(coach.reads, { made: 2, right: 1 });
  assert.equal(r.reads.right, 0);
  assert.equal(ledger.owner, null);
  const system = String((await (async () => { let b: ChatBody | null = null; const spy: ModelClient = { chat: async (s, body) => ((b = body), client.chat(s, body)) }; new Coach("p2", "fake:coach", spy, link, hello, null, { reflexes: true, now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer }).turn("x"); await settle(); return b!; })()).messages[0].content);
  assert.match(system, /Your fighter also has reflexes: a fast decision model \(Jev\)/);
});
