import assert from "node:assert/strict";
import { test } from "node:test";
import WebSocket from "ws";
import { Link, parseFrame } from "../src/link.ts";
import { hello, state } from "./helpers.ts";

test("parseFrame accepts the game's frames and refuses the rest", () => {
  assert.equal(parseFrame("not json"), null);
  assert.equal(parseFrame(JSON.stringify({ type: "plan" })), null);
  assert.equal(parseFrame(JSON.stringify({ type: "state" })), null);
  assert.equal(parseFrame(JSON.stringify({ type: "applied", side: "p3", plan_id: "x" })), null);
  assert.equal(parseFrame(JSON.stringify(hello))?.type, "hello");
  assert.equal(parseFrame(JSON.stringify(state()))?.type, "state");
  assert.equal(parseFrame(JSON.stringify({ type: "event", tick: 1, event: "round_start", round: 1 }))?.type, "event");
  assert.equal(parseFrame(JSON.stringify({ type: "applied", side: "p1", plan_id: "a", ok: true }))?.type, "applied");
});

test("a game connects over a socket, frames flow both ways, the latest state is kept", async () => {
  const link = new Link(0 as number);
  // Port 0 picks a free port; read it back from the server.
  await link.listen();
  const port = (link as unknown as { server: { address(): { port: number } } }).server.address().port;
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise((r) => ws.once("open", r));
  const gotHello = new Promise<{ p1: { id: string } }>((r) => link.once("hello", (h) => r(h)));
  ws.send(JSON.stringify(hello));
  assert.equal((await gotHello).p1.id, "jin");
  const gotState = new Promise<void>((r) => link.once("state", () => r()));
  ws.send(JSON.stringify(state({ tick: 777 })));
  await gotState;
  assert.equal(link.latest?.tick, 777);
  link.receive(JSON.stringify({ type: "event", tick: 1, event: "round_start", round: 1 }));
  assert.equal(link.roundLive, true);
  const received = new Promise<string>((r) => ws.once("message", (d) => r(String(d))));
  assert.equal(link.send({ type: "say", side: "p1", text: "hi" }), true);
  assert.deepEqual(JSON.parse(await received), { type: "say", side: "p1", text: "hi" });
  const applied = new Promise((r) => link.once("applied", (a) => r(a)));
  ws.send(JSON.stringify({ type: "applied", side: "p1", plan_id: "p1-1-0", ok: false, error: "unknown move 9K" }));
  assert.deepEqual(await applied, { type: "applied", side: "p1", plan_id: "p1-1-0", ok: false, error: "unknown move 9K" });
  const gone = new Promise<void>((r) => link.once("disconnected", () => r()));
  ws.close();
  await gone;
  assert.equal(link.send({ type: "end", reason: "test" }), false);
  await link.close();
});
