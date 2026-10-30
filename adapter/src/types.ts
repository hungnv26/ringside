// The protocol (docs/ringside-plan.md "Protocol") and the shapes shared by the adapter's parts.

export type Side = "p1" | "p2";
export const SIDES: Side[] = ["p1", "p2"];
export const other = (s: Side): Side => (s === "p1" ? "p2" : "p1");

export interface MoveInfo {
  input: string;
  name: string;
  startup: number;
  active: number;
  recovery: number;
  damage: number;
  level: string; // high|mid|low|overhead|throw
  notes?: string;
}

export interface FighterInfo {
  id: string;
  name: string;
  archetype?: string;
  max_health: number;
  moves: MoveInfo[];
}

export interface Hello {
  type: "hello";
  version?: string;
  p1: FighterInfo;
  p2: FighterInfo;
  stage: string;
  rounds_to_win: number;
  round_seconds: number;
  seed?: number;
}

export interface RecentAttack {
  input: string;
  name?: string;
  outcome: string; // hit|counter|blocked|whiffed|pending
}

export interface SideState {
  health: number;
  max_health: number;
  meter: number;
  max_meter: number;
  state: string;
  move: string | null;
  x?: number;
  cornered?: boolean;
  plan_age_ticks?: number;
  queued?: string[];
  recent?: RecentAttack[];
}

export interface State {
  type: "state";
  tick: number;
  round: number;
  timer: number;
  wins: [number, number];
  p1: SideState;
  p2: SideState;
  distance: number;
}

export interface GameEvent {
  type: "event";
  tick: number;
  event: string; // round_start|hit|throw|knockdown|super|round_end|match_end
  [k: string]: unknown;
}

export interface Applied {
  type: "applied";
  side: Side;
  plan_id: string;
  ok: boolean;
  error?: string;
}

export type GameFrame = Hello | State | GameEvent | Applied;

export type Mode = "coach" | "script";

/** A self-coding rule: when the fight looks like `when`, do these moves. */
export interface Rule {
  name?: string;
  when: { range?: "close" | "mid" | "far"; opponent?: string; opponent_cornered?: boolean; cornered?: boolean; meter_full?: boolean; health_below?: number; opponent_health_below?: number };
  do: string[];
  weight?: number;
}

// Adapter -> game.
export interface Plan {
  aggression?: number;
  range?: "close" | "mid" | "far" | number;
  block?: number;
  punish?: number;
  anti_air?: number;
  reaction?: "fast" | "normal" | "slow";
  pressure?: number;
  options?: Record<string, number>;
}

export const OPTION_NAMES = ["poke", "string", "rush", "dash", "jump", "throw", "grab", "fireball", "ground_special", "sidestep", "wait", "retreat", "approach", "stance", "reversal"] as const;

export interface PlanFrame {
  type: "plan";
  side: Side;
  plan_id: string;
  plan: Plan;
  /** "reflex" when the side's reflexes (Jev) sent it; the HUD marks the chips. */
  source?: "reflex";
}
export interface QueueFrame {
  type: "queue";
  side: Side;
  plan_id: string;
  moves: string[];
}
export interface SayFrame {
  type: "say";
  side: Side;
  text: string;
}
export interface EndFrame {
  type: "end";
  reason: string;
}
/** The model per side, for the HUD's name plates. */
export interface ModelsFrame {
  type: "models";
  p1: string;
  p2: string;
}
/** A side's coach is waiting for its model (the HUD shows a mark). */
export interface ThinkingFrame {
  type: "thinking";
  side: Side;
  on: boolean;
}
export interface ModeFrame {
  type: "mode";
  mode: Mode;
}
/** Self-coding mode: a plan and the rule set, applied together. */
export interface PolicyFrame {
  type: "policy";
  side: Side;
  plan_id: string;
  plan?: Plan;
  rules?: Rule[];
}
/** The coach's own line about what it sees and is changing (corner talk on the HUD). */
export interface TalkFrame {
  type: "talk";
  side: Side;
  text: string;
}
/** A read: what the coach says the opponent will do next; the game answers with a `read` event. */
export interface PredictFrame {
  type: "predict";
  side: Side;
  plan_id: string;
  what: string;
  source?: "reflex";
}
export type AdapterFrame = PlanFrame | QueueFrame | SayFrame | EndFrame | ModelsFrame | ThinkingFrame | ModeFrame | PolicyFrame | TalkFrame | PredictFrame;

// Model calls, in the OpenAI chat format (the provider translation is models.ts's business).
export interface ToolCall {
  id?: string;
  type?: string;
  function: { name: string; arguments?: string };
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content?: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

export interface ChatBody {
  messages: ChatMessage[];
  tools?: { type: "function"; function: { name: string; description?: string; parameters?: Record<string, unknown> } }[];
  max_tokens?: number;
  [k: string]: unknown;
}

export interface Usage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
  x_input?: number;
  x_cache_read?: number;
  x_cache_write?: number;
}

export interface ChatResult {
  message: { content?: string | null; tool_calls?: ToolCall[] };
  usage: Usage | null;
  tokens: number;
  usd: number | null; // null when the model has no price
  finish: string; // tool_calls | stop | length | refusal
  seconds: number;
}

export interface ModelClient {
  chat(spec: string, body: ChatBody): Promise<ChatResult>;
}
