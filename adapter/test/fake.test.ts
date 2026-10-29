import assert from "node:assert/strict";
import { test } from "node:test";
import { FakeModelClient } from "../src/fake.ts";
import { buildSystemPrompt } from "../src/prompt.ts";
import { hello } from "./helpers.ts";

const names = (r: { message: { tool_calls?: { function: { name: string; arguments?: string } }[] } }) => (r.message.tool_calls ?? []).map((c) => c.function.name);
const args = (r: { message: { tool_calls?: { function: { name: string; arguments?: string } }[] } }, name: string) => JSON.parse(r.message.tool_calls!.find((c) => c.function.name === name)!.function.arguments!);

test("the fake model cycles plans, queues every third call and always captions", async () => {
  const fake = new FakeModelClient();
  const body = { messages: [{ role: "system" as const, content: buildSystemPrompt("p1", hello) }, { role: "user" as const, content: "go" }] };
  const r0 = await fake.chat("fake:coach", body);
  const r1 = await fake.chat("fake:coach", body);
  const r2 = await fake.chat("fake:coach", body);
  assert.deepEqual(names(r0), ["set_plan", "say"]);
  assert.deepEqual(names(r1), ["set_plan", "say"]);
  assert.deepEqual(names(r2), ["set_plan", "queue", "say"]);
  assert.deepEqual(args(r0, "set_plan"), { aggression: 0.3, range: "close" });
  assert.deepEqual(args(r1, "set_plan"), { aggression: 0.9, range: "mid" });
  assert.deepEqual(args(r2, "set_plan"), { aggression: 0.3, range: "far" });
  assert.deepEqual(args(r2, "queue"), { moves: ["2HK", "236K"] }); // Jin has 236K
  assert.equal(r0.finish, "tool_calls");
  assert.equal(r0.usd, 0);
  assert.ok(r0.tokens > 40);
});

test("the fake model queues only 2HK for a fighter without 236K", async () => {
  const fake = new FakeModelClient();
  const body = { messages: [{ role: "system" as const, content: buildSystemPrompt("p2", hello) }, { role: "user" as const, content: "go" }] };
  await fake.chat("fake:coach", body);
  await fake.chat("fake:coach", body);
  const r2 = await fake.chat("fake:coach", body);
  assert.deepEqual(args(r2, "queue"), { moves: ["2HK"] });
});
