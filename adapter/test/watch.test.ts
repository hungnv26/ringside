// The watchability set: corner talk, reads (predict), and what the prompt says about them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Coach } from "../src/coach.ts";
import { FakeModelClient } from "../src/fake.ts";
import { buildSystemPrompt, buildTurnMessage, eventText, PREDICT_TOOL, READ_WORDS, talkOf, TOOLS, validatePredict } from "../src/prompt.ts";
import type { GameEvent } from "../src/types.ts";
import { FakeLink, hello, settle, state } from "./helpers.ts";

test("the coach tools include predict and the prompt asks for a line of corner talk", () => {
  assert.deepEqual(TOOLS.map((t) => t.function.name), ["set_plan", "queue", "say", "predict"]);
  assert.match(PREDICT_TOOL.function.description ?? "", /6 seconds/);
  for (const w of READ_WORDS) assert.ok((PREDICT_TOOL.function.description ?? "").includes(w), w);
  const system = buildSystemPrompt("p1", hello);
  assert.match(system, /Start every reply with one line of corner talk, under 140 characters/);
  assert.match(system, /predict \(a read on what the opponent does next\)/);
});

test("talkOf takes the first non-empty line, strips quotes and markdown, and caps it", () => {
  assert.equal(talkOf(null), "");
  assert.equal(talkOf("  \n\n**They keep whiffing the dragon.** Blocking more.\nset_plan..."), "They keep whiffing the dragon.** Blocking more.");
  assert.equal(talkOf('"Corner talk here."'), "Corner talk here.");
  assert.equal(talkOf("- bullet line"), "bullet line");
  assert.equal(talkOf("x".repeat(200)).length, 140);
  const long = talkOf(("word ").repeat(40));
  assert.ok(long.length <= 140 && long.endsWith("word…"), long);
});

test("validatePredict keeps a move input or a word and drops the rest", () => {
  assert.equal(validatePredict({ what: "623P" }), "623P");
  assert.equal(validatePredict({ what: " jump! " }), "jump");
  assert.equal(validatePredict({ what: "j.HK" }), "j.HK");
  assert.equal(validatePredict({}), "");
  assert.equal(validatePredict({ what: "a".repeat(40) }).length, 24);
});

test("read events are told only to the side that made them", () => {
  const right: GameEvent = { type: "event", tick: 1, event: "read", side: "p1", what: "623P", right: true, actual: "Rising Dragon" };
  const miss: GameEvent = { type: "event", tick: 2, event: "read", side: "p1", what: "jump", right: false, actual: "" };
  assert.equal(eventText(right, "p1"), 'Your read "623P" came true (Rising Dragon): CALLED IT.');
  assert.equal(eventText(miss, "p1"), 'Your read "jump" missed.');
  assert.equal(eventText(right, "p2"), "");
  const msg = buildTurnMessage("p2", state(), [right], null, []);
  assert.match(msg, /Since your last turn: nothing notable\./);
});

test("the coach sends talk and predict frames and tallies its reads from read events", async () => {
  const link = new FakeLink();
  const c = new Coach("p1", "fake:coach", new FakeModelClient(), link, hello, null, {});
  link.feedState(state());
  link.feedEvent("round_start", { round: 1 }); // fake call 0: talk, plan, say
  await settle();
  const types = link.sent.filter((f) => f.type !== "thinking").map((f) => f.type);
  assert.deepEqual(types, ["talk", "plan", "say"]);
  assert.equal(c.lastTalk, "They keep whiffing the heavy; I am tightening the block and waiting for it.");
  link.feedEvent("knockdown", { side: "p1" }); // fake call 1: plan, say, predict 2HK
  await settle();
  const predict = link.sent.find((f) => f.type === "predict") as unknown as { what: string; plan_id: string } | undefined;
  assert.ok(predict, "a predict frame");
  assert.equal(predict!.what, "2HK");
  assert.equal(predict!.plan_id, "p1-2-2");
  assert.deepEqual(c.reads, { made: 1, right: 0 });
  link.feedApplied("p1", "p1-2-2", true);
  link.feedEvent("read", { side: "p2", what: "jump", right: true, actual: "jump" }); // the other side's read
  link.feedEvent("read", { side: "p1", what: "2HK", right: true, actual: "Sweep" });
  await settle();
  assert.deepEqual(c.reads, { made: 1, right: 1 });
  assert.deepEqual(c.stats().reads, { made: 1, right: 1 });
  c.stop();
});
