# Implementation Plan: Display Hunk Count Information

## Overview

Display hunk navigation information (`Hunk X of Y | ]c: next [c: prev`) above a
specified line and column position using Neovim's virtual text/lines feature.

## Display Format

```
Hunk X of Y | ]c: next [c: prev
```

Where:

- `X` = current hunk number (1-based)
- `Y` = total number of hunks
- `]c` = next hunk keybinding (configurable)
- `[c` = previous hunk keybinding (configurable)

## Implementation Tasks

### Task 1: Create Namespace Module

**Goal**: Set up a dedicated namespace for hunk count display

**Steps**:

1. Create a Lua module file (e.g., `hunk_count_display.lua`)
2. Define a module-local namespace variable with lazy initialization:

   ```lua
   local HUNK_COUNT_NS = nil

   local function get_namespace()
     if HUNK_COUNT_NS == nil then
       HUNK_COUNT_NS = vim.api.nvim_create_namespace("hunk_count_display")
     end
     return HUNK_COUNT_NS
   end
   ```

3. Use `get_namespace()` in all functions that need the namespace
4. Export the namespace ID getter for advanced use cases

**Rationale for Lazy Initialization**:

- Namespace creation is lightweight but not needed until first use
- Allows module to be loaded without side effects
- More flexible for testing

**Acceptance Criteria**:

- Namespace is created lazily on first use
- Namespace ID is accessible to other functions via getter
- Namespace name is unique and descriptive
- Module can be loaded without errors

---

### Task 2: Implement Display Function

**Goal**: Create function to display hunk count above a specified line/column

**Function Signature**:

```lua
function display_hunk_count(bufnr, line, col, current_hunk, total_hunks, next_key, prev_key, extmark_id)
```

**Parameters**:

- `bufnr` (integer): Buffer number (0 for current buffer)
- `line` (integer): Target line (0-indexed)
- `col` (integer): Target column (0-indexed)
- `current_hunk` (integer): Current hunk number (1-based)
- `total_hunks` (integer): Total number of hunks
- `next_key` (string): Keybinding for next hunk (e.g., "]c")
- `prev_key` (string): Keybinding for previous hunk (e.g., "[c")
- `extmark_id` (integer|nil): Existing extmark ID to update, or nil for new

**Steps**:

1. Validate all inputs (buffer, line, column, hunk numbers, keys)
2. Format the display string: `"Hunk X of Y | ]c: next [c: prev"`
3. Create extmark with `virt_lines_above = true`
4. Set `virt_lines_leftcol = true` to place in leftmost column
5. Use `"Comment"` highlight group
6. If `extmark_id` is provided, include it in options to update existing extmark
7. Return the extmark ID (or nil on error)

**Implementation**:

```lua
local function display_hunk_count(bufnr, line, col, current_hunk, total_hunks, next_key, prev_key, extmark_id)
  -- Validate inputs
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer"
  end

  -- Line validation
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line < 0 or line >= line_count then
    return nil, "Line out of bounds"
  end

  -- Column validation (note: with virt_lines_leftcol, col may be ignored, but validate anyway)
  if col < 0 then
    return nil, "Column must be non-negative"
  end

  -- Hunk validation
  if current_hunk < 1 or current_hunk > total_hunks then
    return nil, "Invalid hunk number"
  end

  if total_hunks < 1 then
    return nil, "Total hunks must be at least 1"
  end

  -- Key validation
  if not next_key or next_key == "" then
    return nil, "next_key must be non-empty"
  end

  if not prev_key or prev_key == "" then
    return nil, "prev_key must be non-empty"
  end

  -- Format display text
  local text = string.format("Hunk %d of %d | %s: next %s: prev",
    current_hunk, total_hunks, next_key, prev_key)

  -- Prepare extmark options
  -- Note: When virt_lines_leftcol is true, the column parameter may be ignored
  -- but we still use it for the extmark position tracking
  local opts = {
    virt_lines_above = true,
    virt_lines_leftcol = true,  -- Places in leftmost column, bypassing sign/number columns
    virt_lines = {
      {{text, "Comment"}}
    }
  }

  -- Update existing extmark if ID provided
  -- When updating, position (line/col) can also be changed if needed
  if extmark_id then
    opts.id = extmark_id
  end

  -- Get namespace (lazy initialization)
  local ns = get_namespace()

  -- Create or update extmark
  local success, id = pcall(function()
    return vim.api.nvim_buf_set_extmark(bufnr, ns, line, col, opts)
  end)

  if not success then
    return nil, "Failed to create/update extmark"
  end

  return id, nil
end
```

**Important Notes**:

- Function returns `(extmark_id, error_message)` - check for nil extmark_id to
  detect errors
- When `virt_lines_leftcol = true`, the `col` parameter may be ignored for
  display positioning, but is still used for extmark tracking
- Position updates: If you need to move the display to a different line, pass
  the new line/col and the extmark_id

**Acceptance Criteria**:

- Function accepts all required parameters
- Text is formatted correctly
- Extmark is created/updated successfully
- Returns extmark ID and error message (nil on success, error string on failure)
- Handles nil extmark_id for new extmarks
- Handles invalid buffer numbers gracefully
- Validates all inputs before creating extmark
- Uses pcall for error handling around API calls

---

### Task 3: Implement Cleanup Function

**Goal**: Create function to remove hunk count display

**Function Signature**:

```lua
function clear_hunk_count(bufnr, extmark_id)
```

**Parameters**:

- `bufnr` (integer): Buffer number (0 for current buffer)
- `extmark_id` (integer|nil): Extmark ID to delete, or nil to clear all in
  namespace

**Steps**:

1. If `extmark_id` is provided, delete that specific extmark
2. If `extmark_id` is nil, clear entire namespace for the buffer
3. Handle invalid buffer numbers gracefully

**Implementation**:

```lua
local function clear_hunk_count(bufnr, extmark_id)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "Invalid buffer"
  end

  local ns = get_namespace()

  if extmark_id then
    -- Delete specific extmark
    local success, result = pcall(function()
      return vim.api.nvim_buf_del_extmark(bufnr, ns, extmark_id)
    end)
    if success then
      return result, nil  -- Returns true if extmark was found and deleted
    else
      return false, "Failed to delete extmark"
    end
  else
    -- Clear entire namespace for buffer
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return true, nil
  end
end
```

**Return Value**:

- Returns `(success, error_message)` tuple
- `success` is boolean indicating operation result
- `error_message` is nil on success, error string on failure

**Acceptance Criteria**:

- Function deletes specific extmark when ID provided
- Function clears namespace when ID is nil
- Returns `(success, error_message)` tuple
- Handles invalid buffer numbers gracefully
- Uses pcall for error handling around API calls
- Handles non-existent extmark IDs gracefully (returns false, not error)

---

### Task 4: Verify Positioning Behavior

**Goal**: Confirm that virt_lines_above with virt_lines_leftcol produces desired
display

**Critical Verification**: Before proceeding, test that the combination of
`virt_lines_above` and `virt_lines_leftcol` produces the expected visual result.

**Test Script**:

```lua
-- Quick test to verify positioning
local ns = vim.api.nvim_create_namespace("test")
local bufnr = 0
local line = 10  -- Test line (0-indexed: use 9)
local col = 0

vim.api.nvim_buf_set_extmark(bufnr, ns, line, col, {
  virt_lines_above = true,
  virt_lines_leftcol = true,
  virt_lines = {
    {{"Test: Hunk 1 of 5 | ]c: next [c: prev", "Comment"}}
  }
})
```

**Expected Behavior**:

- Text appears above the specified line
- Text starts at the leftmost column (after sign/number columns if present)
- Text uses Comment highlight
- Text scrolls with the buffer line

**If positioning is incorrect**:

- Try without `virt_lines_leftcol` to see if column positioning works
- Consider using `virt_text_win_col = 0` with `virt_text_pos = "overlay"` as
  alternative
- May need to adjust approach based on actual visual result

**Acceptance Criteria**:

- Positioning test confirms expected behavior
- If not, document actual behavior and adjust plan accordingly

---

### Task 5: Handle Edge Cases and Error Scenarios

**Goal**: Ensure proper behavior in special situations

**Edge Cases to Handle**:

1. **First line (line 0)**:
   - `virt_lines_above` works but may appear above viewport
   - Consider: Is this acceptable or should we suppress display?
   - **Decision**: Allow it - virtual lines above line 0 will display above
     first buffer line

2. **Very long text**:
   - Text may wrap or be truncated by window width
   - **Decision**: Let Neovim handle wrapping naturally, no truncation needed

3. **Multiple windows showing same buffer**:
   - Extmarks are buffer-scoped, all windows show same display
   - **Decision**: This is desired behavior - consistent across windows

4. **Scrolling**:
   - Virtual lines scroll with buffer line
   - **Decision**: Expected behavior - display follows the line

5. **Buffer modifications**:
   - Extmarks automatically adjust with text changes
   - **Decision**: No special handling needed - Neovim handles this

6. **Namespace not initialized**:
   - If namespace creation fails or is called before initialization
   - **Decision**: Initialize namespace lazily on first use, cache result

7. **Extmark update failures**:
   - If extmark_id doesn't exist when updating
   - **Decision**: Return error, caller should create new extmark

8. **Concurrent updates**:
   - Multiple calls updating same extmark simultaneously
   - **Decision**: Neovim API handles this atomically, no special handling
     needed

**Implementation Notes**:

- Most edge cases handled by Neovim automatically
- Document expected behavior in comments
- Add error handling for namespace initialization

---

### Task 6: Export Module API

**Goal**: Create clean public API for the module

**Public Functions**:

```lua
return {
  display = display_hunk_count,
  clear = clear_hunk_count,
  get_namespace = get_namespace,  -- For advanced use cases
}
```

**Usage Example**:

```lua
local hunk_display = require("hunk_count_display")

-- Show hunk count at line 10 (0-indexed: 9), column 5 (0-indexed: 4)
local extmark_id = hunk_display.display(0, 9, 4, 2, 5, "]c", "[c")

-- Update to hunk 3 of 5
hunk_display.display(0, 9, 4, 3, 5, "]c", "[c", extmark_id)

-- Clear when done
hunk_display.clear(0, extmark_id)
```

**Acceptance Criteria**:

- Clean public API exported
- Internal functions are private
- Usage examples work correctly

---

### Task 7: Testing Checklist

**Goal**: Verify implementation works correctly

**Test Cases**:

1. **Basic Display**:
   - [ ] Display appears above target line
   - [ ] Text format is correct
   - [ ] Uses Comment highlight group
   - [ ] Appears in leftmost column

2. **Update Existing**:
   - [ ] Updating with same extmark_id changes text
   - [ ] Position remains correct after update
   - [ ] No duplicate extmarks created

3. **Cleanup**:
   - [ ] Clearing by ID removes specific extmark
   - [ ] Clearing without ID removes all in namespace
   - [ ] No errors when clearing non-existent extmark

4. **Edge Cases**:
   - [ ] Works on line 0 (first line)
   - [ ] Works on last line
   - [ ] Handles invalid buffer gracefully
   - [ ] Handles invalid line/column gracefully
   - [ ] Handles invalid hunk numbers gracefully

5. **Multiple Windows**:
   - [ ] Display appears in all windows showing same buffer
   - [ ] Updates reflect in all windows

6. **Scrolling**:
   - [ ] Display scrolls with buffer line
   - [ ] Display disappears when line scrolls out of view

---

## Technical Specifications

### Positioning Strategy

**Selected Approach**: `virt_lines_above` with `virt_lines_leftcol`

**Rationale**:

- Most reliable for "above line" positioning
- Clean separation from buffer content
- Works consistently across different window configurations
- Left column placement avoids conflicts with sign/number columns

### Highlight Group

- Use `"Comment"` highlight group for all text
- Format: `{{"Hunk X of Y | ]c: next [c: prev", "Comment"}}`

### Performance Considerations

- Extmarks are efficient and update automatically with buffer changes
- Updating existing extmark (by ID) is more efficient than deleting and
  recreating
- Clearing namespace is O(n) but typically only one extmark exists
- No performance concerns for typical use cases

### API Reference

- `nvim_create_namespace()`: Create namespace
- `nvim_buf_set_extmark()`: Create/update extmark
- `nvim_buf_del_extmark()`: Delete specific extmark
- `nvim_buf_clear_namespace()`: Clear all extmarks in namespace
- `nvim_buf_is_valid()`: Validate buffer
- `nvim_buf_line_count()`: Get buffer line count

---

## Alternative Approaches (Not Selected)

### Option B: virt_text with overlay

If column positioning is needed instead of above-line:

```lua
local opts = {
  virt_text = {{text, "Comment"}},
  virt_text_pos = "overlay",  -- Overlay at column position
  -- OR:
  -- virt_text_win_col = col,  -- Fixed window column
  -- virt_text_pos = "inline", -- Insert and shift text
}
```

**Why not selected**: `virt_lines_above` better matches requirement of "above
the line"

---

## Implementation Notes

### Line/Column Indexing

- Neovim API uses 0-indexed lines and columns
- Line 10 in editor = index 9 in API
- Column 5 in editor = index 4 in API
- When using `virt_lines_leftcol = true`, column parameter may be ignored for
  display positioning but is still used for extmark tracking

### Extmark Lifecycle

1. **Create**: Call `display()` without extmark_id → returns new extmark_id
2. **Update**: Call `display()` with existing extmark_id → updates text and
   optionally position
3. **Delete**: Call `clear()` with extmark_id → removes specific extmark
4. **Clear All**: Call `clear()` without extmark_id → removes all extmarks in
   namespace for buffer

### Namespace Management

- One namespace per feature/module
- Namespace created lazily on first use
- Namespace persists for buffer lifetime
- Clearing namespace removes all extmarks in that namespace
- Namespace ID is cached after first creation

### Error Handling Strategy

- All functions return `(result, error_message)` tuples
- Check for nil result or false success to detect errors
- Use pcall around Neovim API calls to catch Lua errors
- Validate inputs before making API calls
- Return descriptive error messages

### Position Updates

- To move display to different line: call `display()` with new line/col and
  existing extmark_id
- Extmark position updates atomically
- Text content updates atomically
- Both can be updated in single call

### Testing Recommendations

1. **Visual Verification**: First test with simple script to verify positioning
2. **Unit Tests**: Test validation logic with various inputs
3. **Integration Tests**: Test full lifecycle (create, update, clear)
4. **Edge Case Tests**: Test with edge cases (line 0, last line, invalid inputs)
5. **Multi-window Tests**: Verify behavior with multiple windows showing same
   buffer
