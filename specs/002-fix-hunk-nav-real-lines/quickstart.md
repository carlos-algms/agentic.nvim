# Quickstart: Fix Hunk Navigation Implementation

**Feature**: 002-fix-hunk-nav-real-lines  
**Estimated Time**: 2-3 hours  
**Prerequisites**: Neovim v0.11.0+, basic Lua knowledge

## Goal

Modify hunk navigation to target the first DIFF_DELETE highlighted line (column 0) instead of virtual line anchors. For pure insertions, fall back to line 1, column 0.

## Quick Reference

**Files to modify**:
- `lua/agentic/ui/hunk_navigation.lua` - Main implementation
- `lua/agentic/ui/hunk_navigation.test.lua` - Tests

**Files to read** (context only):
- `lua/agentic/ui/diff_preview.lua` - Understand NS_DIFF usage
- `lua/agentic/utils/diff_highlighter.lua` - Understand DIFF_DELETE highlights
- `specs/002-fix-hunk-nav-real-lines/research.md` - Technical findings
- `specs/002-fix-hunk-nav-real-lines/data-model.md` - Data structures

## Implementation Checklist

### Step 1: Setup Environment (5 minutes)

```bash
# Ensure you're on the correct branch
git status
# Should show: feat/25-show-rich-diff-on-buffer

# Install dependencies (if needed)
make deps

# Verify current tests pass
make test
```

### Step 2: Read Context (15 minutes)

1. **Understand current behavior**:
   ```bash
   nvim lua/agentic/ui/hunk_navigation.lua
   # Focus on: _get_hunk_anchors() function (lines ~40-60)
   ```

2. **Understand highlight application**:
   ```bash
   nvim lua/agentic/utils/diff_highlighter.lua
   # Focus on: apply_diff_highlights() function
   # Note: Uses vim.highlight.range() with Theme.HL_GROUPS.DIFF_DELETE
   ```

3. **Review research findings**:
   ```bash
   nvim specs/002-fix-hunk-nav-real-lines/research.md
   # Key finding: Use { type = "highlight" } filter in nvim_buf_get_extmarks()
   ```

### Step 3: Write Tests First (TDD) (45 minutes)

**File**: `lua/agentic/ui/hunk_navigation.test.lua`

Add these test cases:

```lua
T["_get_hunk_anchors()"]["returns first deleted line per hunk"] = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    
    -- Apply DIFF_DELETE highlights to lines 10, 11, 12 (0-indexed)
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF, 
        "AgenticDiffDelete", {10, 0}, {10, 10})
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {11, 0}, {11, 10})
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {12, 0}, {12, 10})
    
    local anchors = HunkNavigation._get_hunk_anchors(bufnr)
    
    -- Should return line 10 (first deleted line), not line 12 (anchor)
    eq({ 10 }, anchors)
    
    vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["_get_hunk_anchors()"]["deduplicates multiple highlights on same line"] = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    
    -- Apply multiple highlights to line 10 (word-level changes)
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {10, 0}, {10, 5})
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDeleteWord", {10, 8}, {10, 15})
    
    local anchors = HunkNavigation._get_hunk_anchors(bufnr)
    
    -- Should return line 10 once, not twice
    eq({ 10 }, anchors)
    eq(1, #anchors)  -- Verify only one entry
    
    vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["_get_hunk_anchors()"]["returns line 0 for pure insertions"] = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    
    -- No DIFF_DELETE highlights, only virtual lines (simulated)
    -- In reality, diff_preview.lua creates virtual lines via extmarks
    -- but we're testing the fallback when no highlights exist
    
    local anchors = HunkNavigation._get_hunk_anchors(bufnr)
    
    -- Should return line 0 (line 1 in 1-indexed terms)
    eq({ 0 }, anchors)
    
    vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["_get_hunk_anchors()"]["sorts hunks top to bottom"] = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    
    -- Apply highlights in random order
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {50, 0}, {50, 10})
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {10, 0}, {10, 10})
    vim.highlight.range(bufnr, HunkNavigation.NS_DIFF,
        "AgenticDiffDelete", {30, 0}, {30, 10})
    
    local anchors = HunkNavigation._get_hunk_anchors(bufnr)
    
    -- Should be sorted: 10, 30, 50
    eq({ 10, 30, 50 }, anchors)
    
    vim.api.nvim_buf_delete(bufnr, { force = true })
end
```

**Run tests** (they should fail):
```bash
make test
# Expected: 4 failures (tests for new behavior)
```

### Step 4: Implement Changes (60 minutes)

**File**: `lua/agentic/ui/hunk_navigation.lua`

**Modify `_get_hunk_anchors()` function**:

```lua
--- Get all hunk positions (first deleted line per hunk)
--- @param bufnr number
--- @return integer[] positions 0-indexed line numbers of first deleted line per hunk
function M._get_hunk_anchors(bufnr)
    local state = get_state(bufnr)
    if state.anchors_cache then
        return state.anchors_cache
    end

    -- Query all highlight extmarks in NS_DIFF namespace
    local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_DIFF,
        0,
        -1,
        { details = true, type = "highlight" }
    )

    -- Deduplicate deleted lines using set
    local deleted_lines = {}
    for _, extmark in ipairs(extmarks) do
        local _, row, _, details = unpack(extmark)
        
        -- Filter for DIFF_DELETE highlights only
        if details and details.hl_group == Theme.HL_GROUPS.DIFF_DELETE then
            deleted_lines[row] = true
        end
    end

    -- Convert set to sorted array
    local positions = {}
    for line_num in pairs(deleted_lines) do
        table.insert(positions, line_num)
    end
    table.sort(positions)

    -- Fallback for pure insertions (no DIFF_DELETE highlights)
    if #positions == 0 then
        positions = { 0 }  -- Line 1 in 1-indexed terms
    end

    state.anchors_cache = positions
    return positions
end
```

**Update function comment**:

```lua
--- Get all hunk positions (first deleted line per hunk)
--- Previously returned virtual line anchor positions (last deleted line).
--- Now returns first deleted line positions for more intuitive navigation.
--- Falls back to line 0 (line 1 in 1-indexed) for pure insertions.
--- @param bufnr number
--- @return integer[] positions 0-indexed line numbers where hunks begin
```

**No changes needed** to other functions:
- `find_hunk()` - Already handles indexing correctly
- `navigate_hunk()` - Already positions at column 0 via `normal! NG`
- `get_scroll_cmd()` - Signature unchanged (still uses anchor line for hunk size calculation)

### Step 5: Verify Tests Pass (10 minutes)

```bash
# Run tests
make test

# Expected: All tests pass (including new ones)
```

### Step 6: Manual Testing (20 minutes)

1. **Open Neovim with plugin**:
   ```bash
   nvim -u tests/minimal_init.lua
   ```

2. **Create test scenario**:
   ```lua
   -- In Neovim command mode
   :lua << EOF
   local diff_preview = require("agentic.ui.diff_preview")
   local bufnr = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
       "line 1",
       "line 2 - old",
       "line 3 - old",
       "line 4 - old",
       "line 5"
   })
   
   -- Simulate diff: lines 2-4 will be deleted, replaced with new content
   diff_preview.show_diff({
       file_path = vim.api.nvim_buf_get_name(bufnr),
       diff = {
           old = "line 2 - old\nline 3 - old\nline 4 - old",
           new = "line 2 - new\nline 3 - new"
       },
       get_winid = function() return vim.api.nvim_get_current_win() end
   })
   EOF
   ```

3. **Test navigation**:
   - Press configured "next hunk" key (default: `]h`)
   - **Expected**: Cursor moves to line 2, column 0 (first deleted line)
   - **Before fix**: Would have moved to line 4 (last deleted line/anchor)

4. **Test pure insertion**:
   ```lua
   -- Create buffer with only insertions (new file)
   :lua << EOF
   local bufnr = vim.api.nvim_create_buf(false, true)
   diff_preview.show_diff({
       file_path = "/tmp/newfile.txt",
       diff = {
           old = "",
           new = "line 1\nline 2\nline 3"
       },
       get_winid = function() return vim.api.nvim_get_current_win() end
   })
   EOF
   ```
   - Press "next hunk" key
   - **Expected**: Cursor at line 1, column 0

### Step 7: Run Full Validation (15 minutes)

```bash
# Run all checks
make validate

# This runs:
# - make format (StyLua)
# - make luals (type checking)
# - make luacheck (linting)
# - make test (all tests)

# Expected: All checks pass (exit code 0)
```

**If any check fails**:
- Read log file: `.local/agentic_<check>_output.log`
- Fix issues
- Re-run `make validate`

### Step 8: Commit Changes (10 minutes)

```bash
# Stage changes
git add lua/agentic/ui/hunk_navigation.lua
git add lua/agentic/ui/hunk_navigation.test.lua

# Commit with descriptive message
git commit -m "fix(ui): navigate to first deleted line in hunks

- Change _get_hunk_anchors() to query DIFF_DELETE highlights instead of
  virtual line anchors
- Deduplicate highlights by line number (word-level changes)
- Sort hunk positions top to bottom
- Fall back to line 1, column 0 for pure insertions
- Add tests for deduplication, sorting, and edge cases

Fixes confusion where navigation landed on last deleted line (anchor)
instead of first deleted line. Users now see the beginning of changes
when navigating hunks.

Ref: specs/002-fix-hunk-nav-real-lines/spec.md"

# Verify commit
git show --stat
```

## Troubleshooting

### Tests Fail: "No highlights found"

**Cause**: `vim.highlight.range()` may not persist extmarks immediately

**Fix**: Use `vim.api.nvim_buf_set_extmark()` directly in tests:
```lua
vim.api.nvim_buf_set_extmark(bufnr, NS_DIFF, row, 0, {
    end_row = row,
    end_col = 10,
    hl_group = "AgenticDiffDelete"
})
```

### Luacheck Error: "accessing undefined variable Theme"

**Cause**: Missing import

**Fix**: Add at top of `hunk_navigation.lua`:
```lua
local Theme = require("agentic.theme")
```

### Navigation Lands on Wrong Line

**Cause**: Off-by-one error in indexing conversion

**Fix**: Verify conversion in `find_hunk()`:
```lua
-- positions[new_index + 1] gets value from 1-indexed Lua array
-- + 1 converts 0-indexed API line to 1-indexed cursor line
return positions[new_index + 1] + 1, new_index
```

### Performance Slow with Large Diffs

**Cause**: Too many extmarks to query

**Fix**: Already optimized with:
- Caching (`anchors_cache`)
- `type = "highlight"` filter (reduces query result size)
- Set-based deduplication (O(n) not O(n²))

## Next Steps

After implementation:

1. **Generate tasks**: Run `/speckit.tasks` to create detailed task breakdown
2. **Code review**: Create PR for review against constitution principles
3. **Update documentation**: Add entry to CHANGELOG.md if needed
4. **User testing**: Test with real diffs in various file types

## Resources

- [Neovim API docs](https://neovim.io/doc/user/api.html#nvim_buf_get_extmarks())
- [spec.md](spec.md) - Feature specification
- [research.md](research.md) - Technical research findings
- [data-model.md](data-model.md) - Data structures reference
- [plan.md](plan.md) - Complete implementation plan
