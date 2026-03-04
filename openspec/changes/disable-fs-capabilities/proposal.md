# Change: Disable FS capabilities and reload buffers on tool complete

## Why

ACP providers handle file reads/writes through the client when
`readTextFile`/`writeTextFile` capabilities are announced. By
disabling these capabilities, providers read/write files directly
on disk — removing client-side file handling complexity. However,
Neovim buffers become stale when files change externally. We need
to trigger buffer reloads when file-related tool calls complete.

## What changes

- Remove `fs` capability declaration from ACP initialization
  (set both to `false`, already done on current branch)
- Remove `fs/read_text_file` and `fs/write_text_file` handler
  methods from `ACPClient`; keep notification branches as
  warning logs
- Add buffer reload logic in `SessionManager.on_tool_call_update`
  when file-mutating tool calls (`edit`, `create`, `write`,
  `delete`, `move`) reach `completed` status
- Use `vim.cmd.checktime()` to detect disk changes, with a
  `FileChangedShell` autocommand that force-reloads buffers
  (even those with unsaved changes) without prompting — matching
  Cursor/Zed behavior

## Impact

- Affected specs: none (new capability)
- Affected code:
  - `lua/agentic/acp/acp_client.lua` — remove fs handlers,
    keep capabilities as `false`
  - `lua/agentic/session_manager.lua` — add checktime call
    on completed file-related tool calls
  - `lua/agentic/utils/file_system.lua` — `read_file` and
    `write_file` kept (used by `chat_history.lua`); only
    `acp_client.lua` call sites removed
