# 0005. Generic ACPClient, no per-provider adapters

- Status: accepted
- Last updated: 2026-05-16
- Commits: 65981da, fa66ff1
- Related: PR #162, PR #14

## Context

Early versions shipped a per-provider adapter file (one Lua module per
provider) that translated provider quirks into a normalised internal shape.
As more providers were added (Claude, Gemini, Codex, OpenCode, Cursor, Auggie,
Vibe), the adapters duplicated ~90% of the same code to handle small field
differences (`rawInput.new_string` vs `newString`, missing `content` on `edit`
kind, `locations` fallback). Adding a provider required a new adapter file
even when the provider conformed to ACP.

## Current decision

A single generic `ACPClient` handles every provider. Provider quirks are
absorbed inline in `ACPClient.__build_tool_call_message` and a few sibling
protected methods (`__handle_tool_call`, `__handle_tool_call_update`,
`__handle_request_permission`, `__handle_session_update`). Each quirk carries
an inline comment naming the provider that needs it.

Adding a new provider requires only a config entry under
`Config.acp_providers`. No adapter file is created unless the provider
deviates from ACP in ways not yet handled by `ACPClient`.

## Consequences

- Quirks accumulate in one file. Without discipline, the file becomes a
  catch-all. Comments naming the affected provider are mandatory so quirks can
  be located and revisited.
- The protected methods are the public extension point for subclasses if a
  future provider truly cannot be handled inline. None override them today.
- Provider conformance to ACP is the path of least resistance; non-conforming
  providers visibly add to one file rather than hide behind their own module.

## Rejected / superseded alternatives

| Option                                                         | Reason rejected                                                                                                                |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Per-provider adapter modules (original design, fa66ff1)        | Duplicated translation code across providers; new providers required new files even when ACP-conformant. Replaced in 65981da.  |
| Strategy/hook-point pattern with per-provider strategy objects | Same duplication tax with extra indirection; no observable benefit over inline quirks for the small number of deviations seen. |

## Changelog

| Date       | Commit  | Change                                                               |
| ---------- | ------- | -------------------------------------------------------------------- |
| 2026-05-16 |         | Initial decision recorded (post-hoc).                                |
| 2026-03-20 | 65981da | Removed per-provider adapter modules; inlined quirks in `ACPClient`. |
| 2025-12-19 | fa66ff1 | (Superseded) Introduced dedicated per-provider adapter modules.      |
