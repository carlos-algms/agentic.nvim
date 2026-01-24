# Research: Permission Hint Keybindings

**Feature**: 001-permission-hint-keybinds  
**Date**: 2026-01-24

## Summary

No research phase was required for this feature. All technical questions were answered during specification and clarification phases through direct code inspection.

## Questions Resolved Pre-Planning

### 1. How to identify edit tool calls?

**Decision**: Use `tracker.kind` field  
**Rationale**: The `tool_call_blocks` tracker object already contains a `kind` field that identifies tool type ("edit", "bash", etc.). No additional prop drilling or parameter passing needed.  
**Verification**: Confirmed in `message_writer.lua:507-522` where `tracker.kind` is used for display formatting.

### 2. How to access dynamic keybindings?

**Decision**: Read from `Config.keymaps.diff_preview.{next_hunk,prev_hunk}`  
**Rationale**: Config is globally accessible and already used by other modules (HunkNavigation, ChatWidget) for the same purpose.  
**Verification**: Confirmed in `hunk_navigation.lua:182` and `chat_widget.lua:414` which use identical pattern.

### 3. Where should hint line be positioned?

**Decision**: After the "--- ---" separator line  
**Rationale**: User clarification confirmed placement after separator maintains clear visual separation.  
**Layout**: `buttons → separator → hint → blank line`

### 4. What text format for hint line?

**Decision**: Plain text without backticks  
**Rationale**: User clarification specified no backticks or special formatting.  
**Format**: `"HINT: ]c next hunk, [c previous hunk"` (using dynamic keybindings from config)

### 5. How does cleanup work?

**Decision**: Automatic via existing `remove_permission_buttons(start_row, end_row)`  
**Rationale**: This function deletes all lines in the range, which includes the hint line since it's inserted between `button_start_row` and `button_end_row`.  
**Verification**: Confirmed in `message_writer.lua:586-595` which uses `nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, {""})`.

## Implementation Complexity

**Estimated Lines of Code**: ~15 lines  
**Files Modified**: 1 (message_writer.lua)  
**Files Added**: 0  
**Risk Level**: Very Low  
**Dependencies**: None (uses existing modules)

## Alternatives Considered

### Alternative 1: Virtual text (extmarks)

**Rejected because**: User originally suggested this but later preferred real lines to leverage existing cleanup mechanism. Virtual text would require separate cleanup logic.

### Alternative 2: Hardcoded keybindings

**Rejected because**: User correctly identified that keybindings are configurable. Hardcoding would not respect user customization.

### Alternative 3: Pass tool type as parameter

**Rejected because**: Tool type is already available in `tracker.kind`. No need to add parameters or prop drilling.

## No Further Research Required

All technical decisions have been made with confidence based on:
- Direct code inspection of existing implementation
- User clarification of ambiguous requirements
- Verification of API availability in Neovim v0.11.0+
- Review of similar patterns in codebase (Config access, keybinding usage)

Implementation can proceed directly to coding phase.
