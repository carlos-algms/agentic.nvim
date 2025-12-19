# Code Style Normalization Checklist

## Context

**Goal:** Normalize LuaCATS annotations across the codebase to follow project style guidelines defined in AGENTS.md.

**Why:** Consistent code style improves maintainability, reduces cognitive load, and ensures better type checking with LuaLS.

**Style Rules (from AGENTS.md):**
1. Always include a space after `---` for both descriptions and annotations
2. Use `?` suffix for optional types (preferred style)
   - ✅ `@param winid? number` (preferred)
   - ❌ `@param winid number|nil` (avoid unless in `fun()` declarations)
3. Exception: In `fun()` type declarations, use explicit `type|nil` due to LuaLS limitation
4. Use `@private` or `@package` for internal implementation details

## Instructions

**⚠️ IMPORTANT: Do NOT batch changes!**

- Fix ONE file at a time
- Run `make luals && make luacheck` after each file
- Update this checklist immediately after fixing each file
- Commit each fix individually with descriptive message
- This ensures changes are traceable and reversible

## Progress Tracking

### Files Using `type|nil` Instead of `?` Syntax

- [ ] `lua/agentic/acp/acp_client.lua`
- [ ] `lua/agentic/acp/acp_diff_handler.lua`
- [ ] `lua/agentic/acp/acp_transport.lua`
- [ ] `lua/agentic/acp/agent_modes.lua`
- [ ] `lua/agentic/session_manager.lua`
- [ ] `lua/agentic/session_registry.lua`
- [ ] `lua/agentic/ui/code_selection.lua`
- [ ] `lua/agentic/ui/file_picker.lua`
- [ ] `lua/agentic/ui/message_writer.lua`
- [ ] `lua/agentic/ui/permission_manager.lua`
- [ ] `lua/agentic/ui/status_animation.lua`
- [ ] `lua/agentic/utils/buf_helpers.lua`
- [ ] `lua/agentic/utils/diff_highlighter.lua`
- [ ] `lua/agentic/utils/file_system.lua`

### Files with Missing Space After `---`

- [ ] `lua/agentic/acp/acp_diff_handler.lua`
- [ ] `lua/agentic/acp/acp_transport.lua`
- [ ] `lua/agentic/acp/agent_instance.lua`
- [ ] `lua/agentic/config.lua`
- [ ] `lua/agentic/config_default.lua`
- [ ] `lua/agentic/init.lua`
- [ ] `lua/agentic/theme.lua`
- [ ] `lua/agentic/ui/window_decoration.lua`
- [ ] `lua/agentic/utils/buf_helpers.lua`

## Completion Criteria

- [ ] All files use `?` syntax for optional types (except in `fun()` declarations)
- [ ] All files have proper space after `---` in annotations
- [ ] All changes pass `make luals && make luacheck`
- [ ] All changes committed individually with conventional commit messages

## Notes

- Total Lua files in project: 30
- Files needing style fixes: 14 (47%)
- Estimated time: ~30-45 minutes (2-3 minutes per file)
