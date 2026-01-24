# Implementation Plan: Permission Hint Keybindings

**Branch**: `001-permission-hint-keybinds` | **Date**: 2026-01-24 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `/specs/001-permission-hint-keybinds/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Add inline hints showing available keybindings for hunk navigation when displaying edit tool permission requests with diff preview. The hint line appears after the "--- ---" separator with text "HINT: ]c next hunk, [c previous hunk" (using dynamic keybindings from Config.keymaps.diff_preview). Implementation leverages existing permission button cleanup mechanism for automatic removal.

## Technical Context

**Language/Version**: Lua 5.1 (LuaJIT 2.1 bundled with Neovim v0.11.0+)  
**Primary Dependencies**: Neovim v0.11.0+ APIs, agentic.nvim internal modules (Config, MessageWriter, PermissionManager, DiffPreview)  
**Storage**: N/A (UI state only)  
**Testing**: mini.test framework with Busted-style emulation  
**Target Platform**: Neovim v0.11.0+ on macOS/Linux/Windows  
**Project Type**: Neovim plugin (single Lua project)  
**Performance Goals**: Hint line renders within same operation as permission buttons (<200ms total)  
**Constraints**: Must not break existing permission flow, automatic cleanup required, multi-tabpage safe  
**Scale/Scope**: Single module modification (message_writer.lua), ~15 lines of code, 1 test file

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### I. YAGNI ✅ PASS
- Feature explicitly requested by user
- No speculative abstractions needed
- Single-purpose: show hint line for edit permissions only
- No "just in case" features added

### II. Simplicity over cleverness ✅ PASS
- Uses existing Neovim APIs (no custom implementations)
- Leverages existing cleanup mechanism (no new error handling)
- Direct string formatting for hint text
- Minimal changes to existing code

### III. No assumptions - verify first ✅ PASS
- Verified existing code structure via file reads
- Confirmed `tracker.kind` contains tool type
- Confirmed `Config.keymaps.diff_preview` structure
- Verified cleanup mechanism operates on line ranges
- Checked how other modules access dynamic keybindings

### IV. DRY - with judgment ✅ PASS
- No code duplication introduced
- Reuses existing line insertion mechanism
- Reuses existing Config access pattern
- No new helper functions needed (too simple)

### V. Decoupling through callbacks ✅ PASS
- No new class dependencies introduced
- Uses existing Config module (stateless utility)
- No callbacks needed (pure UI rendering)

### VI. Multi-tabpage safety ✅ PASS
- MessageWriter is already tabpage-scoped (via SessionManager)
- No module-level state added
- Buffer-local operations only
- No global keymaps

### VII. Validate before commit ✅ PASS
- Will run `make validate` after implementation
- LuaCATS annotations will be added
- Code follows existing style patterns

### VIII. Test-Driven Development ✅ PASS
- Tests will be written first (message_writer.test.lua)
- Test scenarios:
  1. Hint appears for edit permissions with diff preview enabled
  2. Hint does NOT appear for non-edit permissions
  3. Hint does NOT appear when diff preview disabled
  4. Hint uses dynamic keybindings from Config
  5. Hint is removed with permission buttons

**Result**: All gates PASS. No violations. Proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/001-permission-hint-keybinds/
├── plan.md              # This file
├── spec.md              # Feature specification (already exists)
├── checklists/
│   └── requirements.md  # Quality validation (already exists)
└── tasks.md             # Phase 2 output (NOT created yet)
```

### Source Code (repository root)

```text
lua/agentic/
├── config_default.lua   # Already defines keymaps.diff_preview
├── ui/
│   ├── message_writer.lua          # MODIFY: Add hint line logic
│   └── message_writer.test.lua     # MODIFY: Add hint line tests
└── theme.lua            # Already defines comment highlight groups
```

**Structure Decision**: Single project (Neovim plugin). Modification to existing file (`message_writer.lua`) with co-located test file. No new modules needed.

## Complexity Tracking

No violations. This section intentionally left empty.

## Phase 0: Research

### Research Questions

No research needed. All implementation details verified during clarification phase:

1. ✅ **Tool type identification**: Confirmed `tracker.kind` contains tool type ("edit", "bash", etc.)
2. ✅ **Dynamic keybindings**: Confirmed `Config.keymaps.diff_preview.{next_hunk,prev_hunk}` structure
3. ✅ **Cleanup mechanism**: Confirmed `remove_permission_buttons` operates on line range `(start_row, end_row)`
4. ✅ **Hint line positioning**: Clarified with user - after "--- ---" separator
5. ✅ **Text formatting**: Clarified with user - plain text without backticks

### Implementation Approach

**Location**: `lua/agentic/ui/message_writer.lua:display_permission_buttons()` at line ~548

**Logic**:
```lua
-- After inserting "--- ---" separator
table.insert(lines_to_append, "--- ---")

-- Add hint line for edit tools with diff preview enabled
if tracker and tracker.kind == "edit" and Config.diff_preview.enabled then
    local diff_keymaps = Config.keymaps.diff_preview
    local hint_text = string.format(
        "HINT: %s next hunk, %s previous hunk",
        diff_keymaps.next_hunk,
        diff_keymaps.prev_hunk
    )
    table.insert(lines_to_append, hint_text)
end

table.insert(lines_to_append, "")
```

**Cleanup**: Automatic via existing `remove_permission_buttons(start_row, end_row)` which deletes all lines in range.

**Styling**: Comment highlight group (already available in theme).

## Phase 1: Design & Contracts

### Data Model

No new entities. Existing entities remain unchanged:

- **Permission Request** (already exists): Contains `toolCall.toolCallId`, `options[]`
- **Tool Call Block** (already exists): Contains `tool_call_id`, `kind`, `argument`, `diff`

### API Contracts

No external APIs. Internal function signature unchanged:

```lua
--- Display permission request buttons at the end of the buffer
--- @param tool_call_id string
--- @param options agentic.acp.PermissionOption[]
--- @return integer button_start_row Start row of button block
--- @return integer button_end_row End row of button block  
--- @return table<integer, string> option_mapping Mapping from number to option_id
function MessageWriter:display_permission_buttons(tool_call_id, options)
```

Return values remain unchanged (hint line is within the row range).

### Component Interactions

```
User triggers edit tool
  ↓
SessionManager._show_diff_in_buffer()  # Shows diff preview
  ↓
PermissionManager:add_request()
  ↓
MessageWriter:display_permission_buttons()
  ├─ Looks up tracker = tool_call_blocks[tool_call_id]
  ├─ Checks tracker.kind == "edit"
  ├─ Checks Config.diff_preview.enabled
  ├─ Reads Config.keymaps.diff_preview.{next_hunk,prev_hunk}
  ├─ Formats hint text
  └─ Inserts hint line after "--- ---"
  ↓
[Hint line visible to user]
  ↓
User approves/rejects permission
  ↓
MessageWriter:remove_permission_buttons(start_row, end_row)
  ↓
[Hint line automatically deleted with buttons]
```

### Quickstart

**For users**:
1. Trigger an edit tool permission request
2. If diff preview enabled, see hint line below buttons
3. Use displayed keybindings (e.g., `]c`, `[c`) to navigate hunks
4. Approve/reject permission - hint disappears

**For developers**:
1. Modify `lua/agentic/ui/message_writer.lua:display_permission_buttons()`
2. Add conditional logic after "--- ---" separator insertion
3. Read dynamic keybindings from `Config.keymaps.diff_preview`
4. Format and insert hint line
5. Run tests to verify behavior
6. Run `make validate` to ensure code quality

### Test Plan

**Test file**: `lua/agentic/ui/message_writer.test.lua`

**Test scenarios**:
1. **Hint appears for edit permissions with diff preview**
   - Setup: Create edit tool call block, diff preview enabled
   - Action: Call `display_permission_buttons()`
   - Assert: Hint line present after "--- ---"

2. **Hint does NOT appear for bash permissions**
   - Setup: Create bash tool call block
   - Action: Call `display_permission_buttons()`
   - Assert: Hint line absent

3. **Hint does NOT appear when diff preview disabled**
   - Setup: Create edit tool call block, diff preview disabled
   - Action: Call `display_permission_buttons()`
   - Assert: Hint line absent

4. **Hint uses dynamic keybindings**
   - Setup: Change `Config.keymaps.diff_preview` to custom values
   - Action: Call `display_permission_buttons()`
   - Assert: Hint shows custom keybindings

5. **Hint removed with buttons**
   - Setup: Display buttons with hint
   - Action: Call `remove_permission_buttons(start_row, end_row)`
   - Assert: All lines removed including hint

6. **Hint styled with comment highlight**
   - Setup: Display buttons with hint
   - Action: Check extmarks/highlights
   - Assert: Hint line has comment highlight group

## Phase 2: Task Decomposition

**Note**: This phase is executed by `/speckit.tasks` command (NOT `/speckit.plan`).

Will generate `tasks.md` with implementation steps.
