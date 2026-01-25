# Design: Add Side-by-Side Diff View

## Overview

This design document describes the architecture for adding a side-by-side diff
view mode to agentic.nvim's diff preview system using Neovim's native `:diffthis`
command. The solution preserves the existing inline mode while adding a new
split view option.

## Architecture

### High-Level Flow

```
Permission Request (edit tool call)
         |
         v
   DiffPreview.show_diff
         |
         +-- layout == "inline"  --> Current virtual line implementation
         |                            (virtual lines + custom highlights)
         |
         +-- layout == "split"   --> DiffSplitView.show_split_diff
                                          |
                                          +-- Read original file content
                                          +-- Reconstruct full modified file from raw diffs
                                          +-- Create scratch buffer (no disk write)
                                          +-- Create split with nvim_open_win
                                          +-- Set :diffthis in both windows
                                          +-- Neovim handles all diff rendering
```

### Module Structure

#### New Module: `diff_split_view.lua`

**Responsibilities:**

- Reconstruct full modified file from agent's raw partial diffs
- Create and manage split window layout using `nvim_open_win()`
- Create scratch buffer with meaningful name
- Set up `:diffthis` in both windows
- Track split state per tabpage
- Clean up resources on close (`:diffoff`, delete scratch buffer)

**Public API:**

```lua
--- @class agentic.ui.DiffSplitView.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff Raw agent diff (old/new text)

function M.show_split_diff(opts) end
function M.clear_split_diff(tabpage) end
function M.get_split_state(tabpage) end
```

**State Management:**

```lua
--- @class agentic.ui.DiffSplitView.State
--- @field original_winid number Window ID of original file buffer
--- @field original_bufnr number Buffer number of original file
--- @field new_winid number Window ID of scratch buffer window
--- @field new_bufnr number Buffer number of scratch buffer
--- @field file_path string Path to file being diffed

-- Stored in: vim.t[tabpage]._agentic_diff_split_state

-- Buffer-scoped state (per original buffer):
-- vim.b[original_bufnr]._agentic_prev_modifiable - Original modifiable state
-- vim.b[original_bufnr]._agentic_prev_modified - Original modified state
```

#### Modified Module: `diff_preview.lua`

**Changes:**

- Add layout branching logic in `show_diff()` based on `Config.diff_preview.layout`
- Update `clear_diff()` to delegate to split view when applicable
- Keep all existing inline logic intact

**No changes needed:**

- `ToolCallDiff` - NOT used for split view (minifies diffs)
- `DiffHighlighter` - NOT used for split view (`:diffthis` handles it)
- `HunkNavigation` - May need adaptation for diff mode navigation

### Window Layout

**Split View Layout:**

```
┌─────────────────────────┬─────────────────────────────────┐
│   original.lua          │   original.lua (suggestion)     │
│   (original buffer)     │   (scratch buffer)              │
│   modifiable=false      │   modifiable=false              │
│   diffthis              │   diffthis                      │
│                         │                                 │
│   - line 1 (unchanged)  │   - line 1 (unchanged)          │
│   - line 2 (deleted)    │   + line 2 (added)              │
│   - line 3 (changed)    │   + line 3 (changed)            │
│   - line 4 (unchanged)  │   - line 4 (unchanged)          │
│                         │                                 │
│  [READ ONLY]            │  [READ ONLY]                    │
└─────────────────────────┴─────────────────────────────────┘
```

**Properties:**

- Vertical split (50/50 by default, user-resizable)
- **Both buffers are read-only:** `modifiable=false` set on original buffer and scratch buffer
- Original buffer shows actual file content
- Scratch buffer shows FULL file with all changes applied
- Native diff highlights (DiffAdd, DiffDelete, DiffChange, DiffText)
- Automatic synchronized scrolling via 'scrollbind'
- Automatic vertical alignment via diff filler lines

### Data Flow

#### Show Split Diff

1. **Check if new file** - If no original content exists (`old_text` is empty), **fallback to inline mode** and return early
2. **Find or get target window** - Same logic as inline mode:
   - Check if buffer already visible: `vim.fn.bufwinid(bufnr)`
   - If not visible, call `opts.get_winid(bufnr)` to find first non-widget window
   - If no valid window found, return early
3. **Read original file** - Use `FileSystem.read_from_buffer_or_disk()`
4. **Reconstruct modified file:**
   - Extract raw `old_text` and `new_text` from `opts.diff`
   - **DO NOT call `extract_diff_blocks()`** (it minifies by removing unchanged lines)
   - Manually locate where `old_text` appears in original file
   - Replace with `new_text` to build complete modified content
   - Handle multiple diff blocks by applying all changes
5. **Create scratch buffer:**
   - `vim.api.nvim_create_buf(false, true)` - unlisted, scratch
   - `vim.api.nvim_buf_set_name(bufnr, original_path .. " (suggestion)")` - meaningful name
   - `vim.api.nvim_buf_set_lines()` - write modified content
6. **Open split and capture window ID:**
   - **IMPORTANT:** Use `target_winid` from step 2 (found via `opts.get_winid` or buffer visibility check)
   - Create split using `vim.api.nvim_open_win()`:
     ```lua
     local new_winid = vim.api.nvim_open_win(scratch_bufnr, false, {
         split = "right",
         win = target_winid  -- Target window from step 2
     })
     ```
   - `enter = false` preserves cursor (doesn't switch to new window)
   - `split = "right"` creates vertical split on right side
   - Returns window ID for cleanup (store in state)
7. **Enable diff mode:**
   - Original window: Set as context for target window
     - `vim.api.nvim_win_call(target_winid, function() vim.cmd("diffthis") end)`
   - Scratch window: Set as context for new window
     - `vim.api.nvim_win_call(new_winid, function() vim.cmd("diffthis") end)`
   - Neovim automatically sets 'scrollbind', adds filler lines, applies highlights
8. **Set buffer protection (both buffers read-only):**
   - Original buffer:
     - **CRITICAL:** Save BOTH states BEFORE any modification:
       - `vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable`
       - `vim.b[bufnr]._agentic_prev_modified = vim.bo[bufnr].modified`
     - Set `modifiable = false` (prevent edits)
     - Set `modified = true` (prevent accidental `:q` close)
   - Scratch buffer:
     - Set `modifiable = false` (prevent edits, read-only)
     - Can still be closed with `:q` (no modified flag)
9. **Store state:**
   - Save to `vim.t[tabpage]._agentic_diff_split_state`:
     - `original_winid` - Target window ID (from step 2)
     - `original_bufnr` - Original file buffer number
     - `new_winid` - Scratch buffer window ID (returned from `nvim_open_win`)
     - `new_bufnr` - Scratch buffer number
     - `file_path` - File path

#### Clear Split Diff

1. **Retrieve state** - Get split state from `vim.t[tabpage]`
2. **Disable diff mode (if windows still open):**
   - Original window: `vim.cmd("diffoff")` (if window valid)
   - Scratch window: `vim.cmd("diffoff")` (if window valid)
3. **Close scratch window FIRST** - Prevents flicker when buffer is deleted:
   - Check if window still valid: `vim.api.nvim_win_is_valid(new_winid)`
   - Close: `vim.api.nvim_win_close(new_winid, true)`
4. **Delete scratch buffer AFTER** - Happens in background after window closed:
   - `vim.api.nvim_buf_delete(new_bufnr, { force = true })`
5. **Restore original buffer state:**
   - Restore exact original values:
     - `vim.bo[bufnr].modifiable = vim.b[bufnr]._agentic_prev_modifiable`
     - `vim.bo[bufnr].modified = vim.b[bufnr]._agentic_prev_modified`
   - Clear saved state variables:
     - `vim.b[bufnr]._agentic_prev_modifiable = nil`
     - `vim.b[bufnr]._agentic_prev_modified = nil`
6. **Clear state** - Remove from `vim.t[tabpage]`

### Diff Reconstruction Logic

**Challenge:** Agent sends partial diffs (only changed sections), we need full
modified file for `:diffthis`.

**Solution:**

```lua
--- Reconstruct full modified file from agent's partial diffs
--- @param original_lines string[] Original file content
--- @param diff agentic.ui.MessageWriter.ToolCallDiff Agent's diff data
--- @return string[] modified_lines Full modified file content
local function reconstruct_modified_file(original_lines, diff)
    local modified_lines = vim.deepcopy(original_lines)
    
    -- Extract raw old/new text from agent diff
    local old_text = diff.old or ""
    local new_text = diff.new or ""
    
    if old_text == "" then
        -- New file: return new_text as-is
        return vim.split(new_text, "\n")
    end
    
    -- Find where old_text appears in original file (fuzzy matching)
    local old_lines = vim.split(old_text, "\n")
    local new_lines = vim.split(new_text, "\n")
    
    -- Use TextMatcher.find_all_matches() to locate old_text in file
    local matches = TextMatcher.find_all_matches(original_lines, old_lines)
    
    if #matches > 0 then
        -- Apply first match (or all matches if replace_all=true)
        local match = matches[1]
        
        -- Remove old lines
        for i = match.end_line, match.start_line, -1 do
            table.remove(modified_lines, i)
        end
        
        -- Insert new lines
        for i = #new_lines, 1, -1 do
            table.insert(modified_lines, match.start_line, new_lines[i])
        end
    else
        -- Fallback: couldn't locate old_text, show new_text as-is
        -- User will see entire file changed in diff
        return new_lines
    end
    
    return modified_lines
end
```

**Note:** This reconstruction logic is NEW - existing modules minify diffs and
can't be reused.

### Highlight Strategy

**No custom highlights needed!**

`:diffthis` automatically applies Neovim's built-in diff highlights:

- `DiffAdd` - Added lines (green background by default)
- `DiffDelete` - Deleted lines (red background)
- `DiffChange` - Changed lines (yellow/blue background)
- `DiffText` - Word-level changes within changed lines (brighter highlight)

**User customization:**

Users can customize these highlights in their Neovim config:

```lua
vim.cmd("highlight DiffAdd guibg=#2d4a3e")
vim.cmd("highlight DiffDelete guibg=#4a2d2d")
```

**No code changes needed in `theme.lua`** - we use standard Neovim highlights.

### Hunk Navigation

**Challenge:** Current `HunkNavigation` uses extmark-based navigation (finds
extmarks in `NS_DIFF` namespace). This doesn't work in split mode with `:diffthis`.

**Solution:** Detect layout mode and delegate accordingly

**Implementation:**

- **Inline mode:** Use existing extmark-based navigation (current implementation)
- **Split mode:** Delegate to Neovim's native diff navigation (`]c`/`[c`)
- **User keymaps preserved:** User's configured keymaps (`Config.keymaps.diff_preview.next_hunk`/`prev_hunk`) still work
- **How:** When split mode active, user's keymap executes native `]c`/`[c` commands instead of extmark navigation

```lua
--- Navigate to next hunk (handles both inline and split modes)
function M.navigate_next(bufnr)
    -- Check if split view is active for current tabpage
    local split_state = vim.t[vim.api.nvim_get_current_tabpage()]._agentic_diff_split_state
    
    if split_state then
        -- Split mode: Use native diff navigation
        local ok = pcall(vim.cmd, "normal! ]c")
        if ok and Config.diff_preview.center_on_navigate_hunks then
            vim.cmd("normal! zz")
        end
    else
        -- Inline mode: Use existing extmark navigation
        navigate_inline_hunks("next", bufnr)
    end
end
```

**Key Points:**

- User's configured keymaps (default `]c`/`[c`) remain unchanged
- Implementation switches between navigation strategies based on active layout
- No custom navigation logic for split mode - leverage Neovim's native diff capabilities

### Configuration

**Config Extension:**

```lua
--- @class agentic.UserConfig.DiffPreview
--- @field enabled boolean
--- @field layout "inline" | "split"
--- @field center_on_navigate_hunks boolean
diff_preview = {
    enabled = true,
    layout = "split",  -- NEW FIELD (default: "split")
    center_on_navigate_hunks = true,
}
```

**Backwards Compatibility:**

- Default layout: `"split"` (side-by-side view)
- Users can opt into `"inline"` if preferred
- Existing configs without `layout` field will use `"split"` by default
- **NO hot-reload:** Neovim restart required to change layout

### Edge Cases

1. **Empty diff** - No changes between old and new
   - Solution: Don't show split view, show notification "No changes"

2. **New file** - No original content (`old_text` is empty)
   - Solution: **Fallback to inline mode** - show only the new buffer with content, no split. Split view is only meaningful for comparing existing files with modifications. Use existing inline diff preview functionality.

3. **File deletion** - Proposed content is empty (`new_text` is empty)
   - Solution: Show original content on left, empty buffer on right

4. **Multiple diff blocks** - Agent sends multiple old/new pairs
   - Solution: Apply all changes sequentially to reconstruct full file

5. **Cannot locate old_text** - Fuzzy match fails
   - Solution: Fallback to showing new_text as entire file (full diff)

6. **User tries to close original buffer** - User runs `:q` on original buffer
   - Solution: **Buffer is protected** - `modified=true` prevents closure, shows "No write since last change" error
   - User must accept/reject permission to proceed
   - Force close (`:q!`) will fail because buffer is not modifiable

7. **User closes scratch buffer** - User runs `:q` on scratch buffer window
   - Solution: **Allowed** - Neovim automatically calls `:diffoff` when one diff window closes
   - **CRITICAL:** `clear_split_diff()` MUST be called on accept/reject to restore original buffer state
   - Cleanup already handles missing window gracefully (checks `nvim_win_is_valid()` before closing)
   - Original buffer state (modifiable/modified) is restored in step 5 of cleanup regardless of window state

8. **Tabpage switch** - User switches tabs while split is open
   - Solution: Split is per-tabpage, each tab has independent state

9. **Terminal too narrow** - Not enough width for split
   - Solution: Check `vim.o.columns < 120`, fallback to inline or show error

## Testing Strategy

### Unit Tests

**DiffSplitView Module:**

- `reconstruct_modified_file()` correctly applies diffs
- `show_split_diff()` creates correct window/buffer layout
- `clear_split_diff()` cleans up all resources
- Tabpage isolation (state doesn't leak between tabs)
- Edge cases (empty diff, new file, deletion, multiple diffs)

**Integration with HunkNavigation:**

- Navigation works in diff mode using `]c`/`[c`
- Centering works when enabled

### Integration Tests

**Permission Workflow:**

- Show split diff on permission request
- Approve → split closes, changes applied
- Reject → split closes, changes discarded

**Cursor Preservation:**

- Cursor doesn't move when split is opened
- User's window/cursor position restored after close

### Manual Testing

- Large files with many changes
- Files with word-level changes
- Window resize behavior
- Multiple tabpages with different splits
- Terminal width < 120 columns

## Performance Considerations

1. **Scratch buffer** - No disk I/O, faster than temp files
2. **Native diff mode** - Neovim's optimized diff engine
3. **State storage** - Minimal state in `vim.t[tabpage]`
4. **Cleanup** - Automatic cleanup on tabpage close via Neovim scoped storage
5. **Large files** - Diff mode handles large files efficiently

## Code Reuse

**REUSE:**

- `FileSystem.to_absolute_path()` - Path normalization
- `FileSystem.read_from_buffer_or_disk()` - Read original file
- `TextMatcher.find_all_matches()` - Locate old_text in file
- `vim.api.nvim_open_win()` - Create split and get window ID
- `vim.api.nvim_win_call()` - Execute commands in specific window context
- `vim.api.nvim_win_close()` - Close window by ID
- `vim.api.nvim_win_is_valid()` - Check if window still exists
- `BufHelpers.execute_on_buffer()` - Safe buffer operations

**DO NOT USE:**

- ~~`ToolCallDiff.extract_diff_blocks()`~~ - Minifies diffs
- ~~`ToolCallDiff.minimize_diff_blocks()`~~ - Removes unchanged lines
- ~~`DiffHighlighter.apply_diff_highlights()`~~ - `:diffthis` handles it
- ~~`FileSystem.save_to_disk()`~~ - Use scratch buffer

**NEW CODE NEEDED:**

- `reconstruct_modified_file()` - Build full file from partial diffs
- Split window creation with cursor preservation
- Diff mode setup/teardown
- Adapted hunk navigation for diff mode

## Alternatives Considered

### 1. Continue with Virtual Lines + Custom Highlights

**Pros:** Consistent with current implementation

**Cons:** Reinvents diff mode, more complex, harder to maintain

**Decision:** Rejected - Native diff mode is simpler and more powerful

### 2. Write Suggestion File to Disk

**Pros:** Simpler buffer management

**Cons:** Unnecessary I/O, file watching conflicts, cleanup complexity

**Decision:** Rejected - Scratch buffer is sufficient and faster

### 3. Use `extract_diff_blocks()` for Split View

**Pros:** Reuses existing code

**Cons:** Minifies diffs (removes unchanged lines), doesn't work for full file
view

**Decision:** Rejected - Need full file content for `:diffthis`

### 4. Floating Window Overlay

**Pros:** Modern UI, doesn't affect window layout

**Cons:** Limited space, harder to read large diffs, less familiar UX

**Decision:** Rejected - Traditional split is more practical for diffs

### 5. Temporary Tab with vimdiff

**Pros:** Native vimdiff features

**Cons:** Breaks workflow, requires tab switching, cleanup complexity

**Decision:** Rejected - Too disruptive to user workflow