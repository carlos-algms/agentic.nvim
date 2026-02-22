**Parallelism:** Tasks 1 and 2 MUST be dispatched as parallel
sub-agents in the foreground (do NOT use `run_in_background`).
They are independent and touch different code. Task 3 depends on
both completing first. Task 4 depends on 3. Task 5 depends on 4.

## 1. Extract welcome header helper

- [x] 1.1 Write tests for the header helper: given provider name
  and session ID, returns formatted welcome string
- [x] 1.2 Extract from `SessionManager:new_session` into
  module-level `generate_welcome_header(provider_name, session_id)`
- [x] 1.3 Update `new_session` to call the extracted helper
- [x] 1.4 Run `make validate`

## 2. Extract `_schedule_history_resend(messages)`

- [x] 2.1 Write tests for `_schedule_history_resend(messages)`:
  - Sets `_history_to_send` to the provided messages array
  - Does NOT set `_is_first_message` (caller responsibility)
- [x] 2.2 Implement `SessionManager:_schedule_history_resend(messages)`
- [x] 2.3 Update `restore_from_history` to call it instead of
  setting flags inline (keep its `_is_first_message = false`)
- [x] 2.4 Run `make validate`

## 3. Implement `switch_provider`

- [x] 3.1 Write tests for `switch_provider`:
  - Blocks when `is_generating`
  - Soft cancels old ACP session (cancel session, reset
    session_id, clear permissions, clear todo list)
  - Preserves chat widget buffers, chat history, file list,
    code selection
  - Gets new agent instance from `Config.provider`
  - Calls `new_session` (reuses existing mode/slash/header logic)
  - Calls `_schedule_history_resend(chat_history.messages)`
  - Sets `_is_first_message = true`
- [x] 3.2 Implement `SessionManager:switch_provider()` — reads
  `Config.provider`, no prop drilling
- [x] 3.3 Run `make validate`

## 4. Add public API

- [x] 4.1 Add `Agentic.switch_provider(opts?)` in `init.lua`
  (`opts = { provider?: ProviderName }`). If `opts.provider` set,
  update `Config.provider` and switch. If nil, show picker, set
  `Config.provider` on selection; no-op on cancel. Same pattern
  as `Agentic.new_session`.
- [x] 4.2 Run `make validate`

## 5. Add `<localLeader>s` keymap

- [x] 5.1 Add `switch_provider = "<localLeader>s"` to
  `config_default.lua` under `keymaps.widget`
- [x] 5.2 Bind keymap in `chat_widget.lua` `_bind_keymaps()` for
  all widget buffers (same pattern as `close`)
- [x] 5.3 Run `make validate`

## 6. Update README

- [x] 6.1 Add `switch_provider()` to the Commands table
- [x] 6.2 Add `<localLeader>s` to the Built-in Keybindings table
- [x] 6.3 Add `switch_provider` to the keymaps customization
  example
- [x] 6.4 Add "Switch Providers" to the features list

## 7. Final verification

- [x] 7.1 Run `make validate` — all checks pass
- [x] 7.2 Manual smoke test: open session, chat, switch provider
  via `<localLeader>s`, verify header appears, submit prompt,
  verify history is sent
