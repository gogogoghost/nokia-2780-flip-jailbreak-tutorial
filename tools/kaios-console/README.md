# kaios-console

Bun-based REPL for the KaiOS system app (Nokia 2780 Flip) remote debugger.

Firefox 84's DevTools front end does not render asynchronous evaluation
results from this device's forked devtools-server (preview works, Enter
shows nothing). This tool talks the RDP protocol directly and prints
evaluation results and `console.log` output.

## Requirements

- [Bun](https://bun.sh) 1.x
- Device in ADB mode with **Remote Debugger** enabled (port 6200)

## Run

```bash
adb forward tcp:6200 tcp:6200
bun run index.ts
```

## Features

- Evaluates JS in the chrome/system-app context (same target Firefox
  connects to), not just the DOM inspector
- **Real-time console events**: a resident event loop prints
  `consoleAPICall` / `pageError` as they arrive, so `setTimeout`
  callbacks and async code show output without another command
- `sys` alias = system-app window: `sys.ExternalScreenManager`, ...
- Command history (up/down arrows), persisted to `~/.kaios-console.history`
- Tab completion: chrome globals, system-app globals, and members of
  common system-app objects (`sys.ExternalScreenManager.<TAB>`)
- Multiline input for unbalanced brackets
- `help` / `history` / `quit` commands

## Example

```
js> 1+1
2
js> console.log("hello", {k: 1})
hello | <Object>
js> sys.ExternalScreenManager ? "ok" : "missing"
ok
```

## How it works

1. Connects to `127.0.0.1:6200` (RDP over TCP)
2. `listProcesses` → parent (b2g chrome) process → `getTarget` → `attach`
3. `startListeners` for console events, injects `sys` alias
4. Each command goes through `evaluateJSAsync`; a resident event loop
   prints `consoleAPICall` / `pageError` as they arrive (so timers and
   async callbacks show output live) and routes `evaluationResult` to
   the pending command

Bun-native APIs: `Bun.connect` (socket), `Bun.file` / `Bun.write`
(history), `process.env.HOME`. The only node module is `node:readline`
— Bun has no line-editing API, and readline is the minimal compatible
way to get history / Tab-completion in a TTY.
