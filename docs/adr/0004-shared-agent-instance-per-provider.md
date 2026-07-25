# 0004. Single shared AgentInstance per Provider

- Status: accepted
- Last updated: 2026-07-25
- Commits:
- Related:

> The decision below still holds. Its **per-tab framing is superseded by ADR
> 0008**: sessions are keyed by an integer registry key, not by a tabpage, and
> the isolation unit is the session. Read 0008 for the ownership model; this ADR
> only answers how many subprocesses exist.

## Context

A user may run several independent chats against the same **Provider** (e.g.
`claude-agent-acp`). The plugin must decide how many subprocesses to spawn and
where ACP **Session** ids live.

The Agent Client Protocol multiplexes many `session/new` ids over a single
JSON-RPC stream. Spawning one subprocess per tab would either duplicate that
multiplexing in the plugin or ignore the protocol's design.

## Current decision

One **AgentInstance** per **Provider** name, held module-level on the ACP
module. The instance owns one subprocess and one **ACPClient**. Each
**SessionManager** opens its own **ACP Session** id on that shared client;
routing is keyed by `session_id` via `ACPClient.subscribers` and
`__with_subscriber`.

The **SessionRegistry** owns **SessionManager** instances, keyed by session key
(ADR 0008). The AgentInstance is referenced, not owned, by each SessionManager.

## Consequences

- Isolation between sessions is enforced at the session_id boundary, not at the
  process boundary. A subscriber bug that leaks state across `session_id` keys
  produces cross-session leakage with no process-level firewall.
- Provider crashes affect every session using that provider.
  `_drain_pending_callbacks` must reject every pending RPC across all sessions
  on transition to `disconnected` or `error`.
- Adding a provider does not require new process-management code; only a config
  entry under `acp_providers`.
- Background sessions keep their subscriber registered, so a session that is
  visible in no tabpage still receives `session/update` traffic. That is what
  makes background generation work, and it is why `SessionManager._destroyed`
  has to gate every handler.

## Rejected / superseded alternatives

| Option                       | Reason rejected                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| One subprocess per tabpage   | Duplicates the ACP multiplexing the protocol already provides. The natural protocol path is many sessions on one client. |
| Subprocess pool keyed by tab | Same objection plus pool management overhead.                                                                            |

## Changelog

| Date       | Commit | Change                                                                 |
| ---------- | ------ | ---------------------------------------------------------------------- |
| 2026-05-16 |        | Initial decision recorded.                                             |
| 2026-07-25 |        | Per-tab framing superseded by ADR 0008; subprocess decision unchanged. |
