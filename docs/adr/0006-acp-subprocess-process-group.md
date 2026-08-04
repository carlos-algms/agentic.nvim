# 0006. Spawn ACP subprocesses in their own process group

- Status: accepted
- Last updated: 2026-05-18
- Commits:
- Related:

## Context

Several ACP providers ship as a Node wrapper that re-execs a native binary
(e.g. `codex-acp.js` uses `spawnSync` with no signal handlers). When the
plugin sends `SIGTERM` to the wrapper on `VimLeavePre`, the wrapper dies but
the native grandchild is reparented to `init`/`launchd` and keeps running.

`process:kill(signum)` from libuv only signals the direct child PID, so any
wrapper that does not forward signals leaks its descendants. Observed in `ps`
as `PPID 1` native `codex-acp` binaries after `:q`.

## Current decision

`acp_transport.create_stdio_transport` spawns every ACP child with
`uv.spawn({ detached = true })` so the child becomes its own session and
process-group leader (`setsid`).

`transport:stop` signals the whole group via `uv.kill(-pid, 15)` then
`uv.kill(-pid, 9)` on POSIX. Windows still uses `process:kill`; libuv's
detached flag maps to `DETACHED_PROCESS` there and process groups behave
differently.

Regression test:
``lua/agentic/acp/acp_transport.test.lua::"kills descendant processes when wrapper does not forward signals"``.

## Consequences

- Wrappers that do not forward signals (codex-acp.js today, any future
  `spawnSync`/`exec`-style wrapper) are reaped cleanly.
- ACP children survive a hard kill of nvim (`kill -9`, OOM, segfault):
  they no longer receive `SIGHUP` from nvim's controlling-tty teardown, and
  nothing else reaps them. Clean exits (`:q`, `:qa`, terminal close that
  triggers `VimLeavePre`) still tear them down via
  `AgentInstance:cleanup_all`.
- Children get no controlling tty. ACP agents are headless stdio servers, so
  this is invisible to them.

## Rejected / superseded alternatives

| Option | Reason rejected |
| --- | --- |
| Keep `detached = false`, kill direct PID only | Original behaviour. Leaks codex-acp native grandchildren on every quit. |
| Walk descendants with `pgrep -P` on stop | Works without spawn-flag changes and keeps crash-case cleanup via parent pgrp, but adds per-shutdown fork+exec and a race window where new grandchildren spawned during the walk are missed. |
| File upstream fix in `codex-acp.js` to forward sigs | Right long-term, but does not help users until they upgrade. Pursue in parallel. |
| `PR_SET_PDEATHSIG` so children die with nvim | Linux-only, not exposed by libuv, would require an FFI shim. Not worth it for the hard-kill edge case. |

## Changelog

| Date       | Commit | Change                                                                                  |
| ---------- | ------ | --------------------------------------------------------------------------------------- |
| 2026-05-18 |        | Initial decision: detached spawn + group kill so non-signal-forwarding wrappers reap cleanly. |

## Sources

- `codex-acp.js`: `spawnSync(binaryPath, ..., { stdio: "inherit" })` with no
  signal handlers — upstream at `zed-industries/codex-acp:npm/bin/codex-acp.js`.
- `kill(2)`: negative pid targets the process group on POSIX.
- libuv `uv_spawn` with `UV_PROCESS_DETACHED` calls `setsid` on POSIX.
