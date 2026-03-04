## Context

ACP sessions are provider-scoped. Switching providers requires a new
ACP session on the target provider. The existing session restoration
already supports re-sending history on next prompt via
`_needs_history_send` flags. `SessionManager:new_session` already
handles everything a new session needs: modes, slash commands,
welcome header, default mode selection.

## Goals / Non-goals

- **Goal**: Switch providers mid-conversation preserving chat display
  and history
- **Goal**: Extract `_schedule_history_resend(messages)` as a
  reusable primitive for provider switch, session restore, and
  future model switch
- **Goal**: Reuse `new_session` for session creation — no refactoring
  of mode handling, slash commands, or session setup
- **Goal**: No prop drilling — set `Config.provider` and let
  downstream code read it, same as `Agentic.new_session`
- **Non-goal**: Transfer ACP session state between providers
- **Non-goal**: Support switching while agent is generating

## Decisions

### No prop drilling — use `Config.provider`

`Agentic.new_session` already sets `Config.provider` and lets
`SessionManager` read it. `switch_provider` follows the same
pattern: the public API sets `Config.provider`, then
`SessionManager:switch_provider()` reads it from config. No
provider name passed through the call chain.

### Reuse `new_session` — no handler/mode refactoring

`SessionManager:new_session` already handles:

- Building session handlers (`on_error`, `on_session_update`, etc.)
- Calling `agent:create_session`
- Processing `response.modes` and default mode
- Writing welcome header
- Status animation

`switch_provider` reuses `new_session` directly. The only
difference: instead of calling `_cancel_session` (which clears
everything), `switch_provider` does a targeted soft cancel first,
then delegates to `new_session`.

### `switch_provider` flow

```text
SessionManager:switch_provider()
  1. Soft cancel (inline):
     - agent:cancel_session(session_id)
     - session_id = nil
     - permission_manager:clear()
     - todo_list:clear()
     (skip: widget:clear, file_list:clear, code_selection:clear,
      ChatHistory:new, _needs_history_send = false)
  2. Get new agent instance:
     - AgentInstance.get_instance(Config.provider, on_ready)
     - on_ready: self.agent = client
                 self.current_provider = Config.provider
  3. Call self:new_session() — handles everything else
  4. _schedule_history_resend(chat_history.messages)
     self._is_first_message = true
```

`new_session` calls `_cancel_session` internally, but since
`session_id` is already nil after step 1, `_cancel_session`'s
guard (`if self.session_id then`) skips the destructive parts
(widget clear, list clears). It only resets `permission_manager`,
slash commands, and creates fresh `ChatHistory` — but we need to
preserve history. So `switch_provider` must either:

- Call `new_session({ restore_mode = true })` to skip
  `_cancel_session` entirely, then handle the soft cancel itself
- Or store history before `new_session` and restore after

The cleaner approach: use `restore_mode = true` (which already
skips `_cancel_session`) and do the soft cancel inline before
calling `new_session`.

### `_schedule_history_resend(messages)` as reusable primitive

Extract into a method that only sets the history-send flags —
callers control `_is_first_message` separately since the intent
differs:

```text
function SessionManager:_schedule_history_resend(messages)
  self._needs_history_send = true
  self._history_to_send = messages
end
```

Accepts `messages` as parameter because the source differs:

- `switch_provider`: passes `self.chat_history.messages`
- `restore_from_history`: passes `history.messages` (loaded from
  disk)
- Future `switch_model`: passes `self.chat_history.messages`

Callers set `_is_first_message` independently:

- `switch_provider`: `true` (new provider needs system info)
- `restore_from_history`: `false` (already sent in original)

The consumer (`_handle_input_submit`) is unchanged.

### Welcome header helper

The header format (`# Agentic - <provider> - <session_id>`) is
inline in `new_session`. Extract to a module-level function so both
`new_session` and `switch_provider` can call it. `switch_provider`
writes it via the `on_created` callback of `new_session`.

### Block switch during generation

If `self.is_generating` is true, reject with a notification.

### Public API with opts table

`Agentic.switch_provider(opts?)` where
`opts = { provider?: ProviderName }`:

- `opts.provider` set: set `Config.provider`, switch directly
- nil/omitted: show `SessionRegistry.select_provider` picker,
  set `Config.provider` on selection; no-op on cancel

Same pattern as `Agentic.new_session(opts)`.

### Widget keymap

Default `<localLeader>s` in normal mode, bound to all chat widget
buffers (chat, input, files, code, todos). Calls
`Agentic.switch_provider()` (no args → picker). Configurable via
`keymaps.widget.switch_provider`, same format as other widget
keymaps. Binding follows the same pattern as `close`.

## Sequence diagram

```text
Agentic.switch_provider(opts?)
  |-- opts.provider? → Config.provider = opts.provider
  |-- else → SessionRegistry.select_provider → Config.provider
  |-- cancelled? → return (no-op)
  v
SessionManager:switch_provider()
  |-- is_generating? → reject with notification
  |-- Soft cancel (inline):
  |     |-- agent:cancel_session(session_id)
  |     |-- session_id = nil
  |     |-- permission_manager:clear()
  |     |-- todo_list:clear()
  |-- Save chat_history reference
  |-- AgentInstance.get_instance(Config.provider, on_ready)
  |     v on_ready(client):
  |       self.agent = client
  |       self.current_provider = Config.provider
  |       self:new_session({ restore_mode = true })
  |         → creates ACP session
  |         → handles modes, slash commands, welcome header
  |       Restore chat_history (new_session created fresh one)
  |       _schedule_history_resend(chat_history.messages)
  |       self._is_first_message = true
```

## Risks / Trade-offs

- **Risk**: History may exceed new provider's context window.
  **Mitigation**: Same risk as session restoration; provider
  handles truncation.
- **Risk**: Provider-specific tool call data in history.
  **Mitigation**: `prepend_restored_messages` converts to generic
  text format.

## Future extensibility: model switching

Model is a session property — no session teardown needed:

```text
SessionManager:switch_model(model_name)
  |-- Set model on current session (provider-specific API)
  |-- Write welcome header (optional)
  |-- _schedule_history_resend(chat_history.messages)
  |-- self._is_first_message = true
```

`_schedule_history_resend(messages)` is the only shared primitive
needed. Callers control `_is_first_message` independently.