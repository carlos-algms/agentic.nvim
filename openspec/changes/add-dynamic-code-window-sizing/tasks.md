# Implementation Tasks

## 1. Configuration
- [x] 1.1 Add `max_height` field with default value 15 to `windows.code` configuration in `lua/agentic/config_default.lua`
- [x] 1.2 Update LuaCATS type annotation for `agentic.UserConfig.Windows.Code` to include `max_height number` field
- [x] 1.3 Add `max_height` field with default value 10 to `windows.files` configuration
- [x] 1.4 Update LuaCATS type annotation for `agentic.UserConfig.Windows.Files` to include `max_height number` field

## 2. Extract Reusable Height Calculation Helper
- [x] 2.1 Create private static method `ChatWidget._calculate_dynamic_height(bufnr, max_height)` (place near `_calculate_width()`)
- [x] 2.2 Implement: `local line_count = vim.api.nvim_buf_line_count(bufnr); return math.min(line_count + 1, max_height)`
- [x] 2.3 Add LuaCATS annotations: `@private`, `@param bufnr number`, `@param max_height number`, `@return integer height`
- [x] 2.4 Add inline comment explaining the +1 padding logic

## 3. Abstract Window Create/Resize Pattern
- [x] 3.1 Create `_open_or_resize_dynamic_window(window_name, open_win_opts, max_height, should_display?)` helper method
- [x] 3.2 Handle window creation when window doesn't exist (with dynamic height calculation)
- [x] 3.3 Handle window resizing when window exists (recalculate height, use `nvim_win_set_config`)
- [x] 3.4 Support optional `should_display` parameter (for todos window `Config.windows.todos.display`)
- [x] 3.5 Add proper LuaCATS annotations for the helper method

## 4. Refactor All Windows to Use Abstracted Helper
- [x] 4.1 Refactor code window to use `_open_or_resize_dynamic_window()`
- [x] 4.2 Refactor files window to use `_open_or_resize_dynamic_window()`
- [x] 4.3 Refactor todos window to use `_open_or_resize_dynamic_window()` with `should_display` parameter
- [x] 4.4 Remove all duplicated if/elseif blocks
- [x] 4.5 Verify all three windows use consistent 3-5 line calls to helper

## 5. Unit Tests for Height Calculation (Isolated)
- [x] 5.1 Add new test describe block `"calculate dynamic height"` at top level in chat_widget.test.lua
- [x] 5.2 Create local wrapper function to access private method with diagnostic disable comment
- [x] 5.3 Test: Buffer with 3 lines, max=15, returns 4
- [x] 5.4 Test: Buffer at boundary (9 lines, max=10), returns 10
- [x] 5.5 Test: Buffer exceeding max (20 lines, max=15), returns 15
- [x] 5.6 Test: Empty buffer returns 2 (1 empty line + 1 padding)

## 6. Integration Tests for Window Resizing
- [x] 6.1 Test: Code window resizes from 4 lines → 11 lines when content added
- [x] 6.2 Test: Todos window resizes from 3 lines → 9 lines when content added  
- [x] 6.3 Test: Code window caps at max_height=15 when content exceeds limit
- [x] 6.4 Test: Files window resizes from 3 lines → 7 lines when content added

## 7. Validation
- [x] 7.1 Run `make test-file FILE=lua/agentic/ui/chat_widget.test.lua` to verify all 23 tests pass
- [x] 7.2 Run `make validate` to ensure linting, type checking, and all tests pass
- [x] 7.3 Verify code reduced from ~60 lines of duplicated logic to single abstracted helper
- [x] 7.4 Verify all three windows (code, files, todos) resize dynamically when content changes
