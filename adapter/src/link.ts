// The game link: a WebSocket server the game connects to (docs/ringside-plan.md "Protocol").
// One game at a time; frames from the game are parsed and emitted, frames to the game are
// JSON text. The latest state is kept for the coaches' turns.
import { EventEmitter } from "node:events";
import { WebSocketServer, WebSocket } from "ws";
import type { Beat, AdapterFrame, Applied, GameEvent, GameFrame, Hello, Side, State } from "./types.ts";

export type LinkEvents = {
  hello: [Hello];
  state: [State];
  event: [GameEvent];
  applied: [Applied];
  beat: [Beat];
  connected: [];
  disconnected: [];
};

// Parses one text frame; null when it is not a frame the protocol knows.
export function parseFrame(text: string): GameFrame | null {
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return null;
  }
  if (!v || typeof v !== "object") return null;
  const f = v as Record<string, unknown>;
  switch (f.type) {
    case "hello":
      return f.p1 && f.p2 && typeof f.p1 === "object" && typeof f.p2 === "object" ? (f as unknown as Hello) : null;
    case "state":
      return typeof f.tick === "number" && f.p1 && f.p2 ? (f as unknown as State) : null;
    case "beat":
      return typeof f.n === "number" && f.p1 && f.p2 ? (f as unknown as Beat) : null;
    case "event":
      return typeof f.event === "string" ? (f as unknown as GameEvent) : null;
    case "applied":
      return (f.side === "p1" || f.side === "p2") && typeof f.plan_id === "string" ? (f as unknown as Applied) : null;
    default:
      return null;
  }
}

// What a coach needs from the link; the tests use a fake with the same shape.
export interface GameLink extends EventEmitter<LinkEvents> {
  hello: Hello | null;
  latest: State | null;
  roundLive: boolean;
  send(frame: AdapterFrame): boolean;
}

export class Link extends EventEmitter<LinkEvents> implements GameLink {
  hello: Hello | null = null;
  latest: State | null = null;
  roundLive = false;
  private server: WebSocketServer | null = null;
  private socket: WebSocket | null = null;

  readonly port: number;
  readonly host: string;

  constructor(port: number, host = "127.0.0.1") {
    super();
    this.port = port;
    this.host = host;
  }

  listen(): Promise<void> {
    return new Promise((resolve, reject) => {
      const server = new WebSocketServer({ port: this.port, host: this.host });
      this.server = server;
      server.once("error", reject);
      server.once("listening", () => {
        server.off("error", reject);
        resolve();
      });
      server.on("connection", (socket) => {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
          socket.close(1013, "a game is already connected");
          return;
        }
        this.socket = socket;
        this.emit("connected");
        socket.on("message", (data) => this.receive(String(data)));
        socket.on("close", () => {
          if (this.socket === socket) {
            this.socket = null;
            this.emit("disconnected");
          }
        });
        socket.on("error", () => {});
      });
    });
  }

  // Also reachable by the tests without a socket.
  receive(text: string): void {
    const frame = parseFrame(text);
    if (!frame) return;
    switch (frame.type) {
      case "hello":
        this.hello = frame;
        this.latest = null;
        this.emit("hello", frame);
        break;
      case "state":
        this.latest = frame;
        this.emit("state", frame);
        break;
      case "beat":
        this.latest = { ...frame, type: "state" };
        this.emit("beat", frame);
        break;
      case "event":
        if (frame.event === "round_start") this.roundLive = true;
        if (frame.event === "round_end" || frame.event === "match_end") this.roundLive = false;
        this.emit("event", frame);
        break;
      case "applied":
        this.emit("applied", frame);
        break;
    }
  }

  get connected(): boolean {
    return this.socket !== null && this.socket.readyState === WebSocket.OPEN;
  }

  send(frame: AdapterFrame): boolean {
    if (!this.connected) return false;
    this.socket!.send(JSON.stringify(frame));
    return true;
  }

  sideOf(side: Side): State["p1"] | null {
    return this.latest ? this.latest[side] : null;
  }

  async close(): Promise<void> {
    this.socket?.close();
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
  }
}
