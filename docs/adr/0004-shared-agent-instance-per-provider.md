# 0004. Single shared AgentInstance per Provider

- Status: accepted
- Last updated: 2026-05-16
- Commits:
- Related:

## Context

A user may open multiple tabpages, each running an independent chat against the
same **Provider** (e.g. `claude-agent-acp`). The plugin must decide how many
subprocesses to spawn and where ACP **Session** ids live.

The Agent Client Protocol multiplexes many `session/new` ids over a single
JSON-RPC stream. Spawning one subprocess per tab would either duplicate that
multiplexing in the plugin or ignore the protocol's design.

## Current decision

One **AgentInstance** per **Provider** name, held module-level on the ACP
module. The instance owns one subprocess and one **ACPClient**. Each
**Tabpage** opens its own **ACP Session** id on that shared client; routing is
keyed by `session_id` via `ACPClient.subscribers` and `__with_subscriber`.

The **SessionRegistry** owns per-tab **SessionManager** instances. The
AgentInstance is referenced, not owned, by each SessionManager.

## Consequences

- Per-tab isolation is enforced at the session_id boundary, not at the process
  boundary. A subscriber bug that leaks state across `session_id` keys produces
  cross-tab leakage with no process-level firewall.
- Provider crashes affect every tab using that provider.
  `_drain_pending_callbacks` must reject every pending RPC across all sessions
  on transition to `disconnected` or `error`.
- Adding a provider does not require new process-management code; only a config
  entry under `acp_providers`.

## Rejected / superseded alternatives

| Option                       | Reason rejected                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| One subprocess per tabpage   | Duplicates the ACP multiplexing the protocol already provides. The natural protocol path is many sessions on one client. |
| Subprocess pool keyed by tab | Same objection plus pool management overhead.                                                                            |

## Changelog

| Date       | Commit | Change                     |
| ---------- | ------ | -------------------------- |
| 2026-05-16 |        | Initial decision recorded. |
