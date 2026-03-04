## Context

ACP clients announce filesystem capabilities during
`initialize`. When `readTextFile: false` and
`writeTextFile: false`, compliant providers handle file I/O
directly via their own tools (Read, Write, Edit, etc.). This
means files change on disk without Neovim's knowledge, causing
stale buffers.

## Goals / Non-goals

- **Goal:** Buffers auto-reload when providers modify files
- **Goal:** Remove dead code (fs handler methods) while keeping
  notification routing as warning logs
- **Non-goal:** Handling terminal capability (separate concern)
- **Non-goal:** Per-file targeted reload (checktime is sufficient
  and simpler)

## Decisions

### Buffer reload mechanism: `checktime` + `FileChangedShell`

**Why:** Neovim's built-in `checktime` compares all loaded
buffers against disk timestamps. By default, `checktime` with
`autoread` only auto-reloads *unmodified* buffers and prompts
for modified ones. To match Cursor/Zed behavior (agent changes
always win, no prompts), we register a `FileChangedShell`
autocommand that sets `vim.v.fcs_choice = "reload"`.

From Neovim docs: "If a FileChangedShell autocommand is defined,
you will not get a warning message or prompt — the autocommand
is expected to handle this."

**Force-reload autocommand:** Registered once during session
setup (buffer-local to non-chat buffers, or global with guard).
Sets `vim.v.fcs_choice = "reload"` so modified buffers are
silently reloaded when `checktime` detects disk changes.

**Alternatives considered:**

- `vim.cmd("edit!")` per file — requires knowing exact file
  paths from tool calls; adapters don't always expose paths in
  `tool_call_update`
- `FocusGained` autocommand — only fires on window focus, not
  useful when Neovim stays focused during agent work
- `checktime` alone (no FileChangedShell) — prompts user on
  modified buffers, unlike Cursor/Zed which force-reload

### Hook point: `on_tool_call_update` in SessionManager

**Why:** This is where all tool call status transitions flow.
The `tool_call_update` carries `status` and `tool_call_id`. We
can look up the original `kind` from `message_writer`'s
`tool_call_blocks` tracker.

**Which kinds trigger reload (file-mutating only):**

- `edit` — provider edited a file
- `create` — provider created a new file
- `write` — provider wrote a file
- `delete` — provider deleted a file (buffer becomes stale)
- `move` — provider moved/renamed a file (old path stale)

`read` is excluded — it doesn't mutate files, so checktime
is pointless.

**When:** Only on `status == "completed"`. Failed tool calls
didn't change files.

**Kind lookup:** The `kind` comes from
`message_writer.tool_call_blocks[tool_call_id]` which stores
the initial `ToolCallBlock` (where `kind` is required). If the
tracker or `kind` is missing (e.g., update arrived before
initial tool_call — already handled by MessageWriter returning
early), no reload is triggered.

### No debouncing needed

`checktime` is cheap (stat calls only) and agents aren't fast
enough to cause redundant checks to matter. Direct call on each
completed file-mutating tool call keeps implementation simple
and tests straightforward.

## Risks / Trade-offs

- **Risk:** Provider doesn't respect capability declaration,
  still sends `fs/*` requests
  - **Mitigation:** Keep `_handle_notification` branches for
    `fs/read_text_file` and `fs/write_text_file` — log a
    warning instead of processing. Avoids "unknown method"
    noise for users
- **Risk:** User has unsaved buffer changes when provider edits
  same file
  - **Mitigation:** `FileChangedShell` autocommand forces reload
    without prompting — matches Cursor/Zed behavior where agent
    changes always win. User's unsaved changes are discarded.
    This is acceptable because the agent is the active editor.
- **Risk:** `FileSystem.read_file` / `write_file` used elsewhere
  - **Resolution:** `chat_history.lua` uses both
    `FileSystem.write_file` (line 195) and
    `FileSystem.read_file` (line 209) for session persistence.
    These methods MUST be kept. Only the `acp_client.lua`
    call sites are removed.
