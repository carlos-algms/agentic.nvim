# Provider Switch and Config Options

## Provider switch

`init.lua::apply_provider_switch`:

1. Destroys the current `SessionManager`.
2. Swaps `Config.provider`.
3. Creates a new `AgentInstance` and ACP session.
4. Calls `MessageWriter:replay_history_messages` to repaint the chat buffer from
   prior UI history.

The new provider receives zero prior LLM context:

- no `send_prompt` re-injection
- no bulk history payload

Do not add lazy history resend without explicit user opt-in; it can double-bill
tokens and change perceived behavior.

## Modes, models, thought level

`SessionManager:new_session` dispatches on `SessionCreationResponse`:

- `response.configOptions` present: handled by
  `AgentConfigOptions:_handle_new_config_options`
- otherwise legacy path: `response.modes` populates `AgentModes`, and
  `response.models` populates `AgentModels`

Selectors are keymap-driven:

- `Config.keymaps.widget.change_mode`
- `Config.keymaps.widget.switch_model`
- `Config.keymaps.widget.change_thought_level`

They use `vim.ui.select`. No public `init.lua` entry exists.
