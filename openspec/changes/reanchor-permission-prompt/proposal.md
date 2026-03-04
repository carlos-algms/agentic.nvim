# Change: Reanchor permission prompt after new content

## Why

When an ACP provider sends multiple tool calls or message chunks in
quick succession, new content appends below the permission buttons.
The buttons scroll out of view and the user misses the prompt entirely.

## What changes

- `PermissionManager` removes and re-renders the active permission
  prompt each time new content is written below it
- `MessageWriter` gains a hook that `PermissionManager` subscribes to,
  triggered after any buffer append while a permission request is
  pending
- Keymaps remain buffer-local and are re-bound after each reanchor
- Auto-scroll continues to target the buffer bottom, which now always
  contains the permission prompt when one is pending

## Impact

- Affected specs: new `permission-prompt` capability
- Affected code:
  - `lua/agentic/ui/permission_manager.lua` - reanchor logic
  - `lua/agentic/ui/message_writer.lua` - post-append callback
