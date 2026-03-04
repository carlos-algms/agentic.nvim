## 1. Remove fs request handler methods from ACPClient

- [x] 1.1 Write tests: `_handle_notification` logs warning
  (not processes) for `fs/read_text_file` and
  `fs/write_text_file`
- [x] 1.2 Replace `fs/read_text_file` and `fs/write_text_file`
  branches in `_handle_notification` with warning-only logs
  (`acp_client.lua:291-300`). Keep branches to avoid
  "unknown method" notifications.
- [x] 1.3 Remove `_handle_read_text_file` method
  (`acp_client.lua:471-490`)
- [x] 1.4 Remove `_handle_write_text_file` method
  (`acp_client.lua:494-511`)
- [x] 1.5 Remove `FileSystem` require from `acp_client.lua`
  (no longer used there)
- [x] 1.6 Add `write` to `KNOWN_ACP_KINDS` in `acp_client.lua`
  (currently missing; without it, `write` tool calls trigger
  "Unknown ACP tool call kind" warnings)

## 2. Add force-reload FileChangedShell autocommand

- [x] 2.1 Write tests for force-reload behavior:
  - `FileChangedShell` autocommand sets
    `vim.v.fcs_choice = "reload"`
  - Buffer with unsaved changes reloads silently
  - Buffer without unsaved changes reloads normally
- [x] 2.2 Register a `FileChangedShell` autocommand that sets
  `vim.v.fcs_choice = "reload"` — suppresses prompts when
  buffers have unsaved changes and files change on disk

## 3. Add buffer reload on tool call completion

- [x] 3.1 Write tests for buffer reload behavior:
  - Completed file-mutating kinds trigger checktime
  - Failed tool calls don't trigger checktime
  - Non-mutating kinds (`read`, `think`, `search`) don't trigger
  - Missing `kind` in tracker doesn't trigger, logs debug
- [x] 3.2 Add constant set of file-mutating tool call kinds:
  `edit`, `create`, `write`, `delete`, `move`
- [x] 3.3 In `on_tool_call_update` handler, look up `kind` from
  `message_writer.tool_call_blocks[tool_call_id]` with nil
  check on both tracker and `kind` field
- [x] 3.4 When `status == "completed"` and kind is file-mutating,
  call `vim.cmd.checktime()`

## 4. Validation

- [x] 4.1 Run `make validate` — all checks must pass

## 5. Manual verification

- [ ] 5.1 Start a session with Claude ACP, ask it to edit a file
  that's open in a buffer, confirm buffer reloads
- [ ] 5.2 Open a file, make unsaved changes, ask agent to edit
  same file — confirm buffer reloads WITHOUT prompting
