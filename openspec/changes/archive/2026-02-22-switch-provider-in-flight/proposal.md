# Change: Switch provider in-flight without losing chat history

## Why

Users lose their entire chat session when switching providers. The
existing session restoration mechanism already re-sends messages on
next prompt. Switching providers in-flight reuses this mechanism,
keeping the chat widget intact and only changing the underlying ACP
provider and session.

## What changes

- Extract `_schedule_history_resend(messages)` — reusable method
  that flags given messages to be prepended on next prompt submit.
  Callers control `_is_first_message` independently. Used by
  provider switch, session restore, and future model switch.
- Extract `generate_welcome_header(provider_name, session_id)` —
  module-level function shared by `new_session` and `switch_provider`
- New `SessionManager:switch_provider()` that reads `Config.provider`
  (already set by caller), cancels the old ACP session without
  clearing UI/history, gets the new agent instance, and calls
  `new_session` which already handles modes, slash commands, and
  everything the new provider sends. Sets history resend flags so
  accumulated messages are sent on next prompt.
- New `Agentic.switch_provider(opts?)` public API where `opts` is
  `{ provider?: ProviderName }`. Sets `Config.provider` if provided,
  shows picker if nil. Same pattern as `Agentic.new_session`.

- Default `<localLeader>s` keymap in normal mode on all chat
  widget buffers to trigger provider switch via picker.
  Configurable under `keymaps.widget.switch_provider`.

## Impact

- Affected specs: `session-persistence`
- Affected code:
  - `lua/agentic/session_manager.lua` — `switch_provider` +
    `_schedule_history_resend` + header extraction
  - `lua/agentic/init.lua` — new `switch_provider` public API
  - `lua/agentic/config_default.lua` — new
    `keymaps.widget.switch_provider` default
  - `lua/agentic/ui/chat_widget.lua` — bind switch_provider
    keymap to all widget buffers
