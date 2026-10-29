import assert from "node:assert/strict";
import { test } from "node:test";
import { ProviderClient, callCost, fromAnthropic, fromChatCompletion, fromResponses, splitSpec, toAnthropic, toResponses } from "../src/models.ts";
import { TOOLS } from "../src/prompt.ts";

const body = { messages: [{ role: "system" as const, content: "rules" }, { role: "user" as const, content: "state" }], tools: TOOLS };

test("Claude requests cache the system text and carry the tools and effort", () => {
  const req = toAnthropic(body, "claude-haiku-5-5", "low") as Record<string, any>;
  assert.equal(req.model, "claude-haiku-5-5");
  assert.equal(req.max_tokens, 4000);
  assert.deepEqual(req.system, [{ type: "text", text: "rules", cache_control: { type: "ephemeral" } }]);
  assert.deepEqual(req.messages, [{ role: "user", content: [{ type: "text", text: "state" }] }]);
  assert.deepEqual(req.output_config, { effort: "low" });
  assert.equal(req.tools.length, 3);
  assert.equal(req.tools[0].name, "set_plan");
  const back = fromAnthropic({ content: [{ type: "tool_use", id: "t1", name: "say", input: { text: "hi" } }], stop_reason: "tool_use", usage: { input_tokens: 10, cache_read_input_tokens: 900, cache_creation_input_tokens: 0, output_tokens: 20 } });
  assert.deepEqual(back.message.tool_calls, [{ id: "t1", type: "function", function: { name: "say", arguments: '{"text":"hi"}' } }]);
  assert.equal(back.finish, "tool_calls");
  assert.deepEqual(back.usage, { prompt_tokens: 910, completion_tokens: 20, total_tokens: 930, x_input: 10, x_cache_read: 900, x_cache_write: 0 });
});

test("OpenAI Responses requests and replies translate", () => {
  const req = toResponses(body, "gpt-5.4-mini", "low", "p1") as Record<string, any>;
  assert.equal(req.instructions, "rules");
  assert.deepEqual(req.input, [{ role: "user", content: "state" }]);
  assert.deepEqual(req.reasoning, { effort: "low" });
  assert.equal(req.prompt_cache_key, "p1");
  assert.equal(req.tools[1].name, "queue");
  const back = fromResponses({ output: [{ type: "function_call", call_id: "c1", name: "set_plan", arguments: '{"aggression":0.7}' }], usage: { input_tokens: 100, output_tokens: 30, input_tokens_details: { cached_tokens: 80 } } });
  assert.equal(back.finish, "tool_calls");
  assert.equal(back.message.tool_calls?.[0].function.arguments, '{"aggression":0.7}');
  assert.equal(back.usage.x_cache_read, 80);
  assert.equal(back.usage.x_input, 20);
});

test("chat completions replies translate, and the cost uses the price table", () => {
  const back = fromChatCompletion({ choices: [{ finish_reason: "tool_calls", message: { content: null, tool_calls: [{ id: "x", type: "function", function: { name: "say", arguments: "{}" } }] } }], usage: { prompt_tokens: 50, completion_tokens: 5, total_tokens: 55 } });
  assert.equal(back.finish, "tool_calls");
  assert.equal(callCost({ "a:b": { in: 1, cacheRead: 0.1, out: 10 } }, "a:b", { x_input: 1_000_000, x_cache_read: 1_000_000, completion_tokens: 100_000 }), 1 + 0.1 + 1);
  assert.equal(callCost({}, "a:b", back.usage), null);
  assert.deepEqual(splitSpec("anthropic:claude-haiku-5-5"), { provider: "anthropic", model: "claude-haiku-5-5" });
});

test("a provider call goes through fetch and returns tokens, cost and seconds", async () => {
  let seen: { url: string; body: Record<string, any> } | null = null;
  const fetchFn = (async (url: string | URL | Request, init?: RequestInit) => {
    seen = { url: String(url), body: JSON.parse(String(init?.body)) };
    return new Response(JSON.stringify({ choices: [{ finish_reason: "stop", message: { content: "ok" } }], usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 } }), { status: 200 });
  }) as typeof fetch;
  const client = new ProviderClient("low", fetchFn);
  const r = await client.chat("ollama:outpost-qwen35", body);
  assert.equal(seen!.url, "http://127.0.0.1:11434/v1/chat/completions");
  assert.equal(seen!.body.model, "outpost-qwen35");
  assert.equal(seen!.body.reasoning_effort, "none");
  assert.equal(r.tokens, 12);
  assert.equal(r.message.content, "ok");
  assert.ok(r.seconds >= 0);
  await assert.rejects(client.chat("nope:x", body), /provider one of/);
});
