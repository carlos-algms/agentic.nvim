# Add Side-by-Side Diff View

## 📋 Metadata

- **ID:** `add-side-by-side-diff-view`
- **Status:** `proposed`
- **Author:** Carlos Gomes
- **Created:** 2026-01-25
- **Tags:** `ui`, `diff`, `enhancement`

## 🎯 Problem Statement

The current diff preview uses a unified diff format (single buffer with virtual lines for additions and inline highlights for deletions). While functional, it has limitations:

- Harder to visualize before/after changes side by side
- Less intuitive for users familiar with traditional diff tools (git diff --side-by-side, GitHub PR views)
- Difficult to see context around changes when hunks are far apart
- No visual alignment between original and modified sections

Users need a clearer way to review AI-generated changes before accepting or rejecting them.

## ✅ Proposed Solution

Add a **side-by-side diff view** as an alternative layout to the current unified diff preview, using Neovim's native `:diffthis` command for diff rendering.

### Key Features

1. **Two-column layout:** Left = original buffer, Right = scratch buffer (full file with changes applied)
2. **Native diff mode:** Use `:diffthis` in both windows for automatic diff highlighting and alignment
3. **Synchronized scrolling:** Built-in with `:diffthis` ('scrollbind' option)
4. **No custom diff logic:** Leverage Neovim's native diff engine instead of custom highlights/virtual lines
5. **Configuration-based layout:** User chooses `"inline"` or `"split"` in config
6. **No hot-reload:** Neovim restart required to switch layout styles
7. **Scratch buffer for suggestions:** No disk writes, use named scratch buffer
8. **Both buffers read-only:** Original buffer and scratch buffer both set `modifiable=false`
9. **Preserve cursor position:** Use `nvim_open_win()` with `enter = false` to avoid moving cursor
10. **Preserve existing functionality:** All current keybindings and features still work

### UI Layout (Split Mode)

```
┌─────────────────────────────────────────────────────────────────┐
│ original.lua                   │ original.lua (suggestion)      │
│ (original buffer, read-only)   │ (scratch buffer, read-only)    │
│ diffthis                       │ diffthis                       │
├────────────────────────────────┼────────────────────────────────┤
│  1  function foo()             │  1  function foo()             │
│  2    local x = 1              │  2    local x = 2              │ ← diff highlight
│  3    print(x)                 │  3    print(x)                 │
│  4  end                        │  4    print("debug")           │ ← diff highlight
│                                │  5  end                        │
└────────────────────────────────┴────────────────────────────────┘
```

### Implementation Approach

1. **Configuration option** (in `lua/agentic/config_default.lua`)
   - `diff_preview.layout = "inline" | "split"`
   - Default: `"split"` (side-by-side view preferred)
   - No hot-reload: Neovim restart required to change layout

2. **DiffPreview refactoring** (in `lua/agentic/ui/diff_preview.lua`)
   - Extract layout logic into separate strategies
   - `show_diff()` delegates to layout-specific renderer based on config
   - Inline layout: Keep current implementation (virtual lines + highlights)
   - Split layout: New implementation using `:diffthis`

3. **Split layout implementation**
   - **Find target window:** Use existing `opts.get_winid(bufnr)` callback (same as inline mode)
     - Checks if buffer already visible, otherwise finds first non-widget window
     - Do NOT create windows arbitrarily - reuse existing window finding logic
   - **DO NOT use `extract_diff_blocks()` or `minimize_diff_blocks()`** - these minify diffs by removing unchanged lines
   - **Use raw agent diff data** (`opts.diff.old` and `opts.diff.new`) without processing
   - Create scratch buffer with meaningful name: `vim.api.nvim_buf_set_name(bufnr, original_path .. " (suggestion)")`
   - Apply agent's full diff to create complete modified file content
   - Open vertical split relative to target window using `nvim_open_win()` with `split="right"`
   - Set `:diffthis` in both windows for native diff rendering
   - No custom highlights, no virtual lines - rely entirely on `:diffthis`

4. **Buffer operations (reuse existing utilities)**
   - `FileSystem.to_absolute_path()` - Get absolute path for original file
   - `FileSystem.read_from_buffer_or_disk()` - Read original file content
   - `vim.api.nvim_create_buf(false, true)` - Create scratch buffer (unlisted, scratch)
   - `vim.api.nvim_buf_set_name()` - Name scratch buffer for meaningful titles
   - `vim.api.nvim_buf_set_lines()` - Write modified content to scratch buffer

5. **Window operations**
   - `vim.api.nvim_open_win(bufnr, enter, config)` - Create new split window, returns window ID
   - `vim.api.nvim_win_call(winid, function() ... end)` - Execute commands in specific window context
   - Example: Create split and enable diff mode
   ```lua
   -- Create split window (returns window ID)
   local new_winid = vim.api.nvim_open_win(scratch_bufnr, false, {
       split = "right",
       win = target_winid
   })
   
   -- Enable diff mode in both windows
   vim.api.nvim_win_call(target_winid, function()
       vim.cmd("diffthis")
   end)
   vim.api.nvim_win_call(new_winid, function()
       vim.cmd("diffthis")
   end)
   ```

6. **Diff mode setup**
   - Set `:diffthis` in original file window
   - Set `:diffthis` in scratch buffer window
   - Neovim automatically handles:
     - Diff highlighting (additions, deletions, changes)
     - Vertical alignment with filler lines
     - Synchronized scrolling ('scrollbind')
     - Fold synchronization ('foldmethod=diff')

### Technical Considerations

1. **Raw diff data (no minification):**
   - **CRITICAL:** `extract_diff_blocks()` calls `minimize_diff_blocks()` which removes unchanged lines
   - For split view, we need the FULL file content (original and modified)
   - Extract raw `old_text` and `new_text` from agent diff WITHOUT calling `extract_diff_blocks()`
   - Build complete modified file by applying agent's changes to original content
   - Agent sends partial diffs (`old_text`/`new_text` pairs) - we must reconstruct full file

2. **Scratch buffer advantages:**
   - No disk I/O required
   - Automatic cleanup when buffer deleted
   - No file watching conflicts
   - Can still name buffer for UI clarity: `nvim_buf_set_name(bufnr, "original.lua (suggestion)")`
   - Scratch buffers are `'nomodified'` by default

3. **Cursor preservation and window creation:**
   - NEVER use `:vsplit` or `:split` commands - they don't return window ID and move cursor
   - Use `vim.api.nvim_open_win(bufnr, false, { split = "right", win = target_winid })`
     - Returns window ID for later cleanup
     - `enter = false` preserves cursor position (doesn't switch to new window)
     - `split = "right"` creates vertical split on the right side
   - Store returned window ID in state for cleanup

4. **Native diff mode benefits:**
   - No custom highlight logic needed
   - No virtual lines management
   - Automatic fold handling
   - Built-in synchronized scrolling
   - Respects user's diff colorscheme
   - Less code to maintain

5. **Buffer closing protection:**
   - **Original buffer:** Set `modified=true` AND `modifiable=false` to prevent accidental closure
     - **CRITICAL:** Save original `modifiable` and `modified` states BEFORE any modification
     - Storage: `vim.b[bufnr]._agentic_prev_modifiable` and `vim.b[bufnr]._agentic_prev_modified`
     - User cannot close with `:q` (will show "No write since last change" error)
     - User cannot save changes (buffer is not modifiable)
     - User cannot undo/modify (buffer is read-only)
     - Forces user to accept/reject permission to proceed
   - **Scratch buffer:** Set `modifiable=false` for read-only protection
     - User cannot edit scratch buffer (read-only)
     - Can be closed normally with `:q` (no modified flag needed)
     - Neovim automatically calls `:diffoff` when one diff window closes
     - Acceptable for user to close scratch buffer manually

6. **Cleanup:**
   - Call `:diffoff` in both windows (if still open)
   - **Close split window FIRST** (if still open) - prevents flicker
   - **Delete scratch buffer AFTER** - happens in background after window closed
   - **Restore original buffer's exact states:**
     - `vim.bo[bufnr].modifiable = vim.b[bufnr]._agentic_prev_modifiable`
     - `vim.bo[bufnr].modified = vim.b[bufnr]._agentic_prev_modified`
     - Clear saved state: `vim.b[bufnr]._agentic_prev_modifiable = nil`
     - Clear saved state: `vim.b[bufnr]._agentic_prev_modified = nil`
   - Clear any diff-related options

7. **Edge cases:**
   - Very long lines (horizontal scrolling works automatically with 'scrollbind')
   - Large files (native diff mode is optimized by Neovim)
   - Terminal width too narrow (minimum 120 columns recommended, fallback to inline or show error)
   - **New file creation (no original content):** Fallback to inline mode - show only the new buffer with content, no split. Split view is only for comparing existing files with modifications.
   - File deletion (show "deleted file" message or fallback to inline)
   - Multiple diff blocks (reconstruct full file with all changes applied)

### Code Reuse Opportunities

**REUSE:**
- `FileSystem.to_absolute_path()` - Path normalization
- `FileSystem.read_from_buffer_or_disk()` - Read original file content (handles unsaved changes)
- `HunkNavigation` - Adapt to detect layout mode and delegate to native diff navigation (`]c`/`[c`) when in split mode
- `BufHelpers.execute_on_buffer()` - Execute buffer operations safely
- `vim.api.nvim_open_win()` - Create split window and get window ID for cleanup

**DO NOT USE:**
- ~~`ToolCallDiff.extract_diff_blocks()`~~ - Minifies diffs, removes unchanged lines
- ~~`ToolCallDiff.minimize_diff_blocks()`~~ - Removes context we need for full file view
- ~~`ToolCallDiff.filter_unchanged_lines()`~~ - Not needed with native diff mode
- ~~`DiffHighlighter.apply_diff_highlights()`~~ - `:diffthis` handles highlighting
- ~~`FileSystem.save_to_disk()`~~ - Use scratch buffer instead

**NEW UTILITIES NEEDED:**
- Function to reconstruct full modified file from agent's partial diffs
- Function to apply multiple diff blocks to original content

## 🔄 Alternatives Considered

1. **Continue using custom virtual lines + highlights:** More complex, reinventing Neovim's diff mode
2. **Write suggestion file to disk:** Unnecessary I/O, scratch buffer is sufficient
3. **Hot-reload/toggle between layouts:** Adds complexity, unclear UX benefit for layout preference
4. **Floating window overlay:** More complex to implement, harder to navigate
5. **External diff tool integration:** Breaks self-contained plugin experience

## 📊 Success Criteria

- [ ] Split view uses `:diffthis` for native diff rendering
- [ ] Scratch buffer created with meaningful name (e.g., `"file.lua (suggestion)"`)
- [ ] No disk writes for suggestion buffer
- [ ] Cursor position preserved when opening split
- [ ] **Window creation:** Use `nvim_open_win()` with `split="right"` to create split and capture window ID for cleanup
- [ ] Store returned window ID for proper cleanup (close window on accept/reject)
- [ ] Synchronized scrolling works automatically via 'scrollbind'
- [ ] Full file content shown (not minified diff blocks)
- [ ] Native diff highlights applied (DiffAdd, DiffDelete, DiffChange, DiffText)
- [ ] All existing hunk navigation keybindings work in split view
- [ ] Performance acceptable for large files
- [ ] **New file creation:** Fallback to inline mode (single buffer, no split) when no original file exists
- [ ] **Buffer protection (both buffers read-only):**
  - [ ] Original buffer: Set `modified=true` AND `modifiable=false` to prevent accidental closure
  - [ ] Scratch buffer: Set `modifiable=false` to prevent edits (read-only)
  - [ ] Both buffers cannot be edited by user
  - [ ] Only way to properly close is by accepting/rejecting the permission
  - [ ] **State preservation:** Store original `modifiable` and `modified` values before modification
  - [ ] **State restoration:** Cleanup restores original buffer's exact `modified` and `modifiable` states from saved values
- [ ] README.md updated with new layout mode documentation
- [ ] Config option `diff_preview.layout` added and documented
- [ ] **Cleanup on accept/reject:** `clear_split_diff()` MUST be called to restore original buffer state (modifiable/modified)
- [ ] Cleanup removes scratch buffer and calls `:diffoff`
- [ ] Cleanup works correctly even if user manually closed scratch buffer

## 🚧 Implementation Plan

1. Add `layout` config option to `config_default.lua` (`"inline"` | `"split"`, default `"split"`)
2. Research how to reconstruct full modified file from agent's partial diffs (without using `extract_diff_blocks`)
3. Create utility function to build complete modified content from raw agent diff data
4. Refactor `DiffPreview.show_diff()` to delegate to layout-specific renderers
5. Implement split layout renderer:
   - Read original file content using `FileSystem.read_from_buffer_or_disk()`
   - Build complete modified file from agent's raw diff data
   - Create scratch buffer with `nvim_create_buf(false, true)`
   - Set buffer name with `nvim_buf_set_name()` for UI clarity
   - Write modified content to scratch buffer
   - Create split window using `nvim_open_win(bufnr, false, { split = "right", win = target_winid })`
   - Store returned window ID for cleanup
   - Set `:diffthis` in both windows using `nvim_win_call()`
6. Update `DiffPreview.clear_diff()` to handle split layout cleanup (`:diffoff`, delete scratch buffer, close window)
7. Test hunk navigation keymaps work with diff mode
8. Write tests for edge cases (large files, narrow terminals, new files, multiple diffs)
9. Update README.md with usage instructions and configuration

## 📚 References

- Neovim diff mode: `:help diff-mode`, `:help :diffthis`, `:help :diffoff`
- Window management: `:help nvim_open_win()`, `:help nvim_win_call()`
- Scratch buffers: `:help nvim_create_buf()`, `:help scratch-buffer`
- Buffer naming: `:help nvim_buf_set_name()`
- Diff options: `:help 'scrollbind'`, `:help 'foldmethod'`
- Existing `FileSystem` utilities: `lua/agentic/utils/file_system.lua`
- Existing `BufHelpers` utilities: `lua/agentic/utils/buf_helpers.lua`
- Similar plugins: `diffview.nvim`, `vim-fugitive` (:Gdiffsplit)