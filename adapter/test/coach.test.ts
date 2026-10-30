import assert from "node:assert/strict";
import { test } from "node:test";
import { Coach } from "../src/coach.ts";
import { FakeModelClient } from "../src/fake.ts";
import type { ChatBody, ChatResult, ModelClient } from "../src/types.ts";
import { FakeClock, FakeLink, hello, settle, state } from "./helpers.ts";

function coach(link: FakeLink, clock: FakeClock, client: ModelClient = new FakeModelClient(), over: Record<string, unknown> = {}): Coach {
  return new Coach("p1", "fake:coach", client, link, hello, null, { cadenceMs: 2000, capUsd: 1, now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer, ...over });
}

test("round_start triggers a turn at once and its tool calls reach the game", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const c = coach(link, clock);
  link.feedState(state());
  assert.equal(c.turns, 0);
  link.feedEvent("round_start", { round: 1 });
  await settle();
  assert.equal(c.turns, 1);
  assert.deepEqual(
    link.sent.map((f) => f.type),
    ["thinking", "thinking", "talk", "plan", "say"],
  );
  assert.deepEqual(link.sent.slice(0, 2).map((f) => (f as { on: boolean }).on), [true, false]);
  const plan = link.sent[3] as unknown as { plan: Record<string, unknown>; plan_id: string };
  assert.deepEqual(plan.plan, { aggression: 0.3, range: "close" });
  assert.equal(plan.plan_id, "p1-1-0");
  assert.deepEqual(c.plan, { aggression: 0.3, range: "close" });
  assert.equal(c.lastCaption, "Pressure on.");
  assert.equal(c.status, "coaching");
});

test("turns follow the cadence while the round is live and stop at round_end", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const c = coach(link, clock);
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  await clock.advance(1999);
  assert.equal(c.turns, 1);
  await clock.advance(1);
  assert.equal(c.turns, 2);
  await clock.advance(4000);
  assert.equal(c.turns, 4);
  link.feedEvent("round_end", { winner: "p1", reason: "K.O." });
  await clock.advance(10_000);
  assert.equal(c.turns, 4);
});

test("applied results from the game feed the next prompt, refusals are counted", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const prompts: string[] = [];
  const spy: ModelClient = {
    chat: async (spec: string, body: ChatBody): Promise<ChatResult> => {
      prompts.push(String(body.messages[1].content));
      return new FakeModelClient().chat(spec, body);
    },
  };
  const c = coach(link, clock, spy);
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  link.emit("applied", { type: "applied", side: "p1", plan_id: "p1-1-0", ok: true });
  link.emit("applied", { type: "applied", side: "p2", plan_id: "p2-1-0", ok: false, error: "not mine" });
  await clock.advance(2000);
  assert.equal(c.turns, 2);
  assert.equal(c.plansApplied, 1);
  assert.equal(c.refused, 0);
  assert.match(prompts[1], /Your last tools: set_plan \{"aggression":0\.3,"range":"close"\}: applied\./);
  assert.match(prompts[1], /Your current plan: aggression 0\.3; range close\./);
});

test("a 25% health swing and an own knockdown trigger turns; one turn in flight at most", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  let release: (() => void) | null = null;
  const slow: ModelClient = {
    chat: async (spec: string, body: ChatBody): Promise<ChatResult> => {
      await new Promise<void>((r) => (release = r));
      return new FakeModelClient().chat(spec, body);
    },
  };
  const c = coach(link, clock, slow);
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  assert.equal(c.status, "thinking");
  link.feedEvent("knockdown", { side: "p1" }); // while the first turn is in flight
  link.feedEvent("knockdown", { side: "p2" }); // not ours
  await settle();
  assert.equal(c.turns, 0);
  release!();
  await settle();
  assert.equal(c.turns, 1); // the wanted turn starts now
  release!();
  await settle();
  assert.equal(c.turns, 2);
  link.feedState(state({ p1: { ...state().p1, health: 735 } }));
  await settle();
  link.feedState(state({ p1: { ...state().p1, health: 400 } })); // 34% of max gone since the last turn
  await settle();
  assert.equal(c.status, "thinking");
  release!();
  await settle();
  assert.equal(c.turns, 3);
});

test("the cost cap stops the turns and keeps the plan", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  const fake = new FakeModelClient();
  const pricey: ModelClient = {
    chat: async (spec: string, body: ChatBody): Promise<ChatResult> => ({ ...(await fake.chat(spec, body)), usd: 0.6 }),
  };
  const c = coach(link, clock, pricey);
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  assert.equal(c.status, "coaching");
  await clock.advance(2000);
  assert.equal(c.turns, 2);
  assert.equal(c.status, "out of budget");
  assert.ok(c.usd >= 1);
  await clock.advance(10_000);
  link.feedEvent("round_start", { round: 2 });
  await settle();
  assert.equal(c.turns, 2);
  assert.deepEqual(c.plan, { aggression: 0.9, range: "mid" });
});

test("a model error is counted and the coach carries on", async () => {
  const link = new FakeLink();
  const clock = new FakeClock();
  let fail = true;
  const flaky: ModelClient = {
    chat: async (spec: string, body: ChatBody): Promise<ChatResult> => {
      if (fail) throw new Error("boom");
      return new FakeModelClient().chat(spec, body);
    },
  };
  const c = coach(link, clock, flaky);
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 });
  await settle();
  assert.equal(c.errors, 1);
  assert.equal(c.lastError, "boom");
  assert.equal(c.status, "coaching");
  fail = false;
  await clock.advance(2000);
  assert.equal(c.turns, 2);
  assert.equal(link.sent.filter((f) => f.type !== "thinking").length, 3);
  c.stop();
  assert.equal(c.status, "stopped");
});
