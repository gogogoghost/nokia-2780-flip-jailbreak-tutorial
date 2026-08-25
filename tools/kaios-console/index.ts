#!/usr/bin/env bun
/**
 * kaios-console.ts — KaiOS system-app RDP console (Bun)
 *
 * Connects to the device's remote debugger (6200 via adb forward) and
 * evaluates JavaScript in the chrome (system app) context, printing
 * results and console output that Firefox 84's front end fails to show.
 *
 * Uses Bun-native APIs for networking (Bun.connect), files (Bun.file /
 * Bun.write) and home dir (process.env.HOME). The only node module is
 * node:readline: Bun has no line-editing API, and readline is the
 * minimal compatible way to get history/Tab-completion in a TTY.
 *
 * Usage:
 *   adb forward tcp:6200 tcp:6200
 *   bun run index.ts
 *   bun run index.ts --port 5555
 *
 * Features:
 *   - real-time console events: a resident event loop prints
 *     consoleAPICall / pageError as they arrive, so timers and
 *     async callbacks show up without a follow-up command
 *   - command history (up/down), persisted to ~/.kaios-console.history
 *   - Tab completion of chrome + system-app globals and members
 *   - multiline input for unbalanced brackets
 *   - `sys` alias = system-app window (sys.ExternalScreenManager, ...)
 */
import {
  createInterface,
  type Interface as RLInterface,
  type Completer,
} from "node:readline";

const HOST = "127.0.0.1";
const PORT = 6200;
const HISTORY_FILE = `${process.env.HOME ?? "/root"}/.kaios-console.history`;

// ---------------------------------------------------------------------------
// RDP packet types
// ---------------------------------------------------------------------------

/** Any message on the RDP stream: replies and pushed events alike. */
interface Packet {
  from: string;
  type?: string;
  error?: string;
  message?: string;
  result?: unknown;
  resultID?: string;
  hasException?: boolean;
  exception?: unknown;
  pageError?: Record<string, unknown>;
  [key: string]: unknown;
}

interface ProcessInfo {
  id: number;
  isParent: boolean;
  actor: string;
}

interface Ctx {
  rdp: Rdp;
  consoleActor: string;
  processActor: string;
}

interface CompletionWords {
  sys: string[];
  obj: Record<string, string[]>;
}

interface Requester {
  matches: (p: Packet) => boolean;
  resolve: (p: Packet) => void;
}

/** readline.Interface with the Node-specific history members. */
interface HistoryInterface extends RLInterface {
  history: string[];
  closed: boolean;
}

// ---------------------------------------------------------------------------
// RDP client over Bun.connect
// ---------------------------------------------------------------------------

class Rdp {
  private buf = Buffer.alloc(0);
  private events: Packet[] = [];
  private requesters: Requester[] = [];
  private eventWaiters: ((p: Packet) => void)[] = [];
  private sock: Bun.Socket | null = null;

  /** Feed raw bytes from the socket into the frame buffer. */
  feed(chunk: Uint8Array): void {
    this.buf = Buffer.concat([this.buf, Buffer.from(chunk)]);
    this.drainBuffer();
  }

  bind(sock: Bun.Socket): void {
    this.sock = sock;
  }

  private drainBuffer(): void {
    while (true) {
      const sep = this.buf.indexOf(0x3a); // ':'
      if (sep === -1) return;
      const len = Number(this.buf.subarray(0, sep).toString("utf8"));
      if (Number.isNaN(len)) return;
      const total = sep + 1 + len;
      if (this.buf.length < total) return;
      const body = this.buf.subarray(sep + 1, total);
      this.buf = this.buf.subarray(total);
      this.dispatch(JSON.parse(body.toString("utf8")) as Packet);
    }
  }

  private dispatch(pkt: Packet): void {
    for (let i = 0; i < this.requesters.length; i++) {
      const requester = this.requesters[i];
      if (requester === undefined) continue;
      if (requester.matches(pkt)) {
        this.requesters.splice(i, 1);
        requester.resolve(pkt);
        return;
      }
    }
    const waiter = this.eventWaiters.shift();
    if (waiter !== undefined) {
      waiter(pkt);
    } else {
      this.events.push(pkt);
    }
  }

  /** Send a request and await its reply packet. */
  request(
    to: string,
    type: string,
    extra: Record<string, unknown> = {},
    timeoutMs = 6000,
  ): Promise<Packet> {
    const frame = buildFrame({ to, type, ...extra });
    const { promise, resolve, reject } = Promise.withResolvers<Packet>();
    const timer = setTimeout(() => {
      this.requesters = this.requesters.filter((r) => r.resolve !== resolve);
      reject(new Error(`timeout waiting for ${type} from ${to}`));
    }, timeoutMs);
    this.requesters.push({
      matches: (p: Packet) => p.from === to && !("type" in p),
      resolve: (p: Packet) => {
        clearTimeout(timer);
        resolve(p);
      },
    });
    this.sock?.write(frame);
    return promise;
  }

  /** Await the next server-pushed event (consoleAPICall, evaluationResult, ...). */
  nextEvent(timeoutMs = 2000): Promise<Packet | undefined> {
    const queued = this.events.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    const { promise, resolve } = Promise.withResolvers<Packet | undefined>();
    const timer = setTimeout(() => {
      this.eventWaiters = this.eventWaiters.filter((w) => w !== done);
      resolve(undefined);
    }, timeoutMs);
    const done = (p: Packet) => {
      clearTimeout(timer);
      resolve(p);
    };
    this.eventWaiters.push(done);
    return promise;
  }
}

function buildFrame(msg: Record<string, unknown>): Buffer {
  const payload = Buffer.from(JSON.stringify(msg), "utf8");
  return Buffer.concat([
    Buffer.from(String(payload.length), "utf8"),
    Buffer.from(":"),
    payload,
  ]);
}

// ---------------------------------------------------------------------------
// Type guards for RDP payloads
// ---------------------------------------------------------------------------

function parseProcesses(value: unknown): ProcessInfo[] {
  if (!Array.isArray(value)) return [];
  const out: ProcessInfo[] = [];
  for (const item of value) {
    if (item !== null && typeof item === "object") {
      const o = item as Record<string, unknown>;
      if (typeof o.actor === "string" && typeof o.isParent === "boolean") {
        out.push({
          id: typeof o.id === "number" ? o.id : 0,
          isParent: o.isParent,
          actor: o.actor,
        });
      }
    }
  }
  return out;
}

function parseTarget(value: unknown): { actor: string; consoleActor: string } {
  if (value === null || typeof value !== "object") {
    throw new Error("getTarget returned no process");
  }
  const o = value as Record<string, unknown>;
  if (typeof o.actor !== "string" || typeof o.consoleActor !== "string") {
    throw new Error("getTarget process lacks actor fields");
  }
  return { actor: o.actor, consoleActor: o.consoleActor };
}

// ---------------------------------------------------------------------------
// Console protocol helpers
// ---------------------------------------------------------------------------

async function connect(): Promise<Ctx> {
  const rdp = new Rdp();
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  const sock = await Bun.connect({
    hostname: HOST,
    port: PORT,
    socket: {
      open: () => resolve(),
      error: (sock, err) => reject(new Error(String(err))),
      data: (sock, chunk) => rdp.feed(chunk),
    },
  });
  await promise;
  rdp.bind(sock);
  await rdp.nextEvent(3000); // greeting

  const procs = await rdp.request("root", "listProcesses");
  const parent = parseProcesses(procs.processes).find((p) => p.isParent);
  if (parent === undefined) throw new Error("no parent process in listProcesses");

  const target = await rdp.request(parent.actor, "getTarget");
  const proc = parseTarget(target.process);
  await rdp.request(proc.actor, "attach", {}, 8000);
  try {
    await rdp.request(
      proc.consoleActor,
      "startListeners",
      { listeners: ["ConsoleAPI", "PageError"] },
      5000,
    );
  } catch {
    // listeners are best-effort; evaluation still works
  }
  return { rdp, consoleActor: proc.consoleActor, processActor: proc.actor };
}

const INJECT_SCRIPT = `(() => {
  const w = document.getElementById('systemapp');
  const sys = w && w.contentWindow;
  window.__sys = sys; window.sys = sys; window.__chrome = window;
  const valid = o => {
    try { return Object.getOwnPropertyNames(o).filter(n => /^[A-Za-z_$][\\w$]*$/.test(n)); }
    catch (e) { return []; }
  };
  const sysObjs = ['ExternalScreenManager','ScreenManager','StatusBar',
    'wallpaperManager','Service','PowerManager','document','navigator',
    'console','AppWindowManager','SettingsObserver','DeviceCapabilityManager'];
  const obj = {};
  if (sys) sysObjs.forEach(n => {
    try { const v = sys[n]; if (v && typeof v === 'object') obj[n] = valid(v); } catch (e) {}
  });
  return JSON.stringify({ sys: sys ? valid(sys) : [], obj });
})()`;

function parseWords(value: unknown): CompletionWords {
  const empty: CompletionWords = { sys: [], obj: {} };
  if (typeof value !== "string") return empty;
  try {
    const raw = JSON.parse(value) as Record<string, unknown>;
    const sys = Array.isArray(raw.sys)
      ? raw.sys.filter((n): n is string => typeof n === "string")
      : [];
    const obj: Record<string, string[]> = {};
    if (raw.obj !== null && typeof raw.obj === "object") {
      for (const [k, v] of Object.entries(raw.obj as Record<string, unknown>)) {
        if (Array.isArray(v)) obj[k] = v.filter((n): n is string => typeof n === "string");
      }
    }
    return { sys, obj };
  } catch {
    return empty;
  }
}

/** Inject `sys`/`__sys` aliases and pull completion word lists. */
async function prepare(rdp: Rdp, consoleActor: string): Promise<CompletionWords> {
  const rid = (await rdp.request(consoleActor, "evaluateJSAsync", { text: INJECT_SCRIPT }))
    .resultID;
  if (rid === undefined) return { sys: [], obj: {} };
  const result = await waitEval(String(rid), 6000);
  return parseWords(result);
}

// ---------------------------------------------------------------------------
// Resident event loop: prints console output as it arrives, delivers
// evaluation results to the command that requested them.
// ---------------------------------------------------------------------------

type TimerHandle = ReturnType<typeof setTimeout>;

const pendingEvals = new Map<string, (ev: Packet) => void>();
const pendingTimers = new Map<string, TimerHandle>();

/** Wait for the evaluationResult event matching rid; resolves undefined on timeout. */
function waitEval(rid: string, timeoutMs: number): Promise<unknown> {
  const { promise, resolve } = Promise.withResolvers<unknown>();
  const timer = setTimeout(() => {
    pendingEvals.delete(rid);
    pendingTimers.delete(rid);
    resolve(undefined);
  }, timeoutMs);
  pendingTimers.set(rid, timer);
  pendingEvals.set(rid, resolve);
  return promise;
}

function deliverResult(ev: Packet): void {
  const key = String(ev.resultID ?? "");
  if (key === "") return;
  const resolve = pendingEvals.get(key);
  if (resolve === undefined) return;
  pendingEvals.delete(key);
  clearTimeout(pendingTimers.get(key));
  pendingTimers.delete(key);
  resolve(ev);
}

function onConsoleEvent(ev: Packet): void {
  const msg = ev.message as Record<string, unknown> | undefined;
  const args = msg?.arguments;
  if (Array.isArray(args) && args.length > 0) {
    console.log(args.map(fmt).join(" | "));
  }
}

function onPageError(ev: Packet): void {
  const err = ev.pageError as Record<string, unknown> | undefined;
  const msg = err?.errorMessage;
  if (typeof msg === "string") {
    console.log(`[pageError] ${msg}`);
  }
}

/** Resident event consumer: run for the lifetime of the session. */
async function runEventLoop(rdp: Rdp): Promise<void> {
  while (true) {
    const ev = await rdp.nextEvent(3000);
    if (ev === undefined) continue;
    if (ev.type === "evaluationResult") {
      deliverResult(ev);
    } else if (ev.type === "consoleAPICall") {
      onConsoleEvent(ev);
    } else if (ev.type === "pageError") {
      onPageError(ev);
    }
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function fmt(v: unknown): string {
  if (typeof v === "string") return v;
  if (v === null) return "null";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (typeof v !== "object") return String(v).slice(0, 200);
  const obj = v as Record<string, unknown>;
  if (obj.type === "undefined") return "undefined";
  if (obj.type === "null") return "null";
  if (obj.type === "object") {
    const prev = (obj.preview ?? {}) as Record<string, unknown>;
    const props = prev.properties;
    if (props !== null && typeof props === "object") {
      const parts = Object.entries(props as Record<string, unknown>).map(([k, val]) => {
        const inner =
          val !== null && typeof val === "object"
            ? ((val as Record<string, unknown>).value ?? val)
            : val;
        return `${k}: ${fmt(inner)}`;
      });
      return `{ ${parts.join(", ")} }`;
    }
    if (typeof prev.name === "string") {
      return `${String(obj.class ?? "Object")}(...)`;
    }
    return `<${String(obj.class ?? "object")}>`;
  }
  return String(v).slice(0, 200);
}

function resultText(res: unknown): string | undefined {
  if (typeof res === "string") return res;
  if (res === null || typeof res !== "object") return undefined;
  const r = res as Record<string, unknown>;
  if (r.type === "undefined" || r.type === "null") return undefined;
  return undefined;
}

function formatError(ev: Packet): string {
  const exc = (ev.exception ?? {}) as Record<string, unknown>;
  const prev = (exc.preview ?? {}) as Record<string, unknown>;
  const msg = prev.message ?? exc.message ?? JSON.stringify(exc).slice(0, 200);
  let out = `Error: ${String(msg)}`;
  if (typeof prev.stack === "string") out += `\n${prev.stack}`;
  return out;
}

async function evalAsync(rdp: Rdp, consoleActor: string, text: string): Promise<void> {
  const reply = await rdp.request(consoleActor, "evaluateJSAsync", { text });
  const rid = reply.resultID;
  if (rid === undefined) {
    console.log("(no result id in reply)");
    return;
  }
  const ev = await waitEval(String(rid), 10000);
  if (ev === undefined) {
    console.log("(no result received)");
    return;
  }
  const pkt = ev as Packet;
  if (pkt.hasException === true) {
    console.log(formatError(pkt));
    return;
  }
  const textResult = resultText(pkt.result);
  if (textResult !== undefined) {
    console.log(textResult);
  } else {
    console.log(fmt(pkt.result).slice(0, 2000));
  }
}

// ---------------------------------------------------------------------------
// REPL
// ---------------------------------------------------------------------------

function makeCompleter(words: CompletionWords): Completer {
  return (line: string): [string[], string] => {
    const cur = line.split(" ").pop() ?? "";
    if (cur.includes(".")) {
      const dot = cur.lastIndexOf(".");
      const head = cur.slice(0, dot);
      const tail = cur.slice(dot + 1);
      const members = words.obj[head] ?? [];
      const hits = members.filter((m) => m.startsWith(tail)).map((m) => `${head}.${m}`);
      return [hits, cur];
    }
    const pool = [
      "help", "quit", "exit", "sys", "__sys", "__chrome",
      "console", "document", "window", "navigator", "location",
      "JSON", "Object", "Array", "String", "Number", "Promise",
      ...words.sys.slice(0, 200),
    ];
    const hits = pool.filter((m) => m.startsWith(cur));
    return [hits, cur];
  };
}

const PAIRS: Record<string, string> = { "(": ")", "[": "]", "{": "}" };

function needsContinuation(text: string): boolean {
  const stack: string[] = [];
  let instr: string | null = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (instr !== null) {
      if (c === "\\") {
        i++;
      } else if (c === instr) {
        instr = null;
      }
    } else if (c === '"' || c === "'" || c === "`") {
      instr = c;
    } else if (c === "(" || c === "[" || c === "{") {
      stack.push(c);
    } else if (c === ")" || c === "]" || c === "}") {
      const top = stack[stack.length - 1];
      if (top !== undefined && PAIRS[top] === c) stack.pop();
    }
  }
  return stack.length > 0;
}

/** Promisified readline.question; resolves "" on EOF/close. */
function ask(rl: HistoryInterface, prompt: string): Promise<string> {
  if (rl.closed) return Promise.resolve("");
  const { promise, resolve } = Promise.withResolvers<string>();
  const onClose = () => resolve("");
  rl.once("close", onClose);
  rl.question(prompt, (answer) => {
    rl.removeListener("close", onClose);
    resolve(answer);
  });
  return promise;
}

/** Load persisted history via Bun.file. */
async function loadHistory(): Promise<string[]> {
  const file = Bun.file(HISTORY_FILE);
  if (!(await file.exists())) return [];
  try {
    return (await file.text()).split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

async function saveHistory(rl: HistoryInterface): Promise<void> {
  try {
    await Bun.write(HISTORY_FILE, rl.history.slice(-500).join("\n"));
  } catch {
    // history is best-effort
  }
}

async function main(): Promise<void> {
  console.log(`Connecting to ${HOST}:${PORT} ...`);
  let ctx: Ctx;
  try {
    ctx = await connect();
  } catch (e) {
    console.error(`Connection failed: ${e}`);
    console.error("Run `adb forward tcp:6200 tcp:6200` first.");
    process.exit(1);
  }
  console.log("Connected. Preparing completion context ...");
  const words = await prepare(ctx.rdp, ctx.consoleActor);
  void runEventLoop(ctx.rdp); // resident: prints timers/async console output

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    completer: makeCompleter(words),
  }) as HistoryInterface;
  rl.history = await loadHistory();
  console.log("Ready. Type `help` for usage, Ctrl-D to exit.\n");

  while (true) {
    const line = (await ask(rl, "js> ")).trim();
    if (line === "") {
      if (rl.closed) break;
      continue;
    }
    if (line === "quit" || line === "exit") break;
    if (line === "help") {
      console.log(
        `Commands: help, history, quit/exit, or any JS expression.\n` +
          `  sys          system-app window (sys.ExternalScreenManager, ...)\n` +
          `  up/down      history · Tab completes · multiline for unbalanced brackets`,
      );
      continue;
    }
    if (line === "history") {
      rl.history.forEach((h, i) => console.log(`${i + 1}: ${h}`));
      continue;
    }
    let code = line;
    if (needsContinuation(code)) {
      while (needsContinuation(code)) {
        const more = (await ask(rl, "... ")).trim();
        if (more === "") break;
        code += "\n" + more;
      }
    }
    await evalAsync(ctx.rdp, ctx.consoleActor, code);
  }
  await saveHistory(rl);
  rl.close();
  console.log("Bye.");
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
