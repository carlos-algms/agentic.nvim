local assert = require("tests.helpers.assert")

local FilePicker = require("agentic.ui.file_picker")

describe("FilePicker:scan_files", function()
    local original_system
    local original_cmd_rg
    local original_cmd_fd
    local original_cmd_git

    --- @type agentic.ui.FilePicker
    local picker

    before_each(function()
        original_system = vim.fn.system
        original_cmd_rg = FilePicker.CMD_RG[1]
        original_cmd_fd = FilePicker.CMD_FD[1]
        original_cmd_git = FilePicker.CMD_GIT[1]
        picker = FilePicker.new(vim.api.nvim_create_buf(false, true)) --[[@as agentic.ui.FilePicker]]
    end)

    after_each(function()
        vim.fn.system = original_system -- luacheck: ignore
        FilePicker.CMD_RG[1] = original_cmd_rg
        FilePicker.CMD_FD[1] = original_cmd_fd
        FilePicker.CMD_GIT[1] = original_cmd_git
    end)

    describe("mocked commands", function()
        it("should stop at first successful command", function()
            -- Make all commands available by setting them to executables that exist
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"

            local call_count = 0

            ---@diagnostic disable-next-line: duplicate-set-field -- we must mock it to force specific behavior
            vim.fn.system = function(cmd) -- luacheck: ignore
                call_count = call_count + 1

                if call_count == 1 then
                    return original_system("false")
                else
                    original_system("true")
                    return "file1.lua\nfile2.lua\nfile3.lua\n"
                end
            end

            local files = picker:scan_files()

            -- Should have called system exactly 2 times (first fails, second succeeds)
            assert.are.equal(2, call_count)
            assert.are.equal(3, #files)
        end)
    end)

    describe("real commands", function()
        it("should return same files in same order for all commands", function()
            -- Test rg
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = picker:scan_files()

            -- Test fd
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = original_cmd_fd
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_fd = picker:scan_files()

            -- Test git
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = original_cmd_git
            local files_git = picker:scan_files()

            -- All commands should return more than 0 files
            assert.is_true(#files_rg > 0)
            assert.is_true(#files_fd > 0)
            assert.is_true(#files_git > 0)

            -- All commands should return the same count
            assert.are.equal(#files_rg, #files_fd)
            assert.are.equal(#files_fd, #files_git)

            assert.are.same(files_rg, files_fd)
            assert.are.same(files_fd, files_git)
        end)

        it("should use glob fallback when all commands fail", function()
            local original_exclude_patterns =
                vim.tbl_extend("force", {}, FilePicker.GLOB_EXCLUDE_PATTERNS)

            -- First, get files from rg for comparison
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = picker:scan_files()

            -- Disable all commands to force glob fallback
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"

            -- deps is the temp folder where mini.nvim is installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "deps/")
            -- lazy_repro is the temp folder where plugins are installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "lazy_repro/")
            -- .local is the folder where Neovim is installed during tests in CI
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.local/")
            -- .claude is in global gitignore (rg/fd/git respect it, glob doesn't)
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.claude/")

            local files_glob = picker:scan_files()

            assert.is_true(#files_glob > 0)
            assert.are.same(files_rg, files_glob)

            FilePicker.GLOB_EXCLUDE_PATTERNS = original_exclude_patterns
        end)
    end)
end)

describe("FilePicker keymap fallback", function()
    local child = require("tests.helpers.child").new()

    teardown(function()
        child.stop()
    end)

    before_each(function()
        child.setup()
    end)

    it(
        "should call fallback Tab mapping when completion menu not visible",
        function()
            child.lua([=[
                _G.tab_called = false
                vim.keymap.set("i", "<Tab>", function()
                    _G.tab_called = true
                    return "TAB_CALLED"
                end, { expr = true, desc = "Test Tab mapping" })

                require("agentic.ui.file_picker").new(0)
                vim.cmd([[execute "normal i\<Tab>"]])
            ]=])

            assert.is_true(child.lua_get("_G.tab_called"))
        end
    )

    it(
        "should call fallback CR mapping when completion menu not visible",
        function()
            child.lua([=[
                _G.cr_called = false
                vim.keymap.set("i", "<CR>", function()
                    _G.cr_called = true
                    return "CR_CALLED"
                end, { expr = true })

                require("agentic.ui.file_picker").new(0)
                vim.cmd([[execute "normal i\<CR>"]])
            ]=])

            assert.is_true(child.lua_get("_G.cr_called"))
        end
    )

    it("should NOT call fallback when completion menu is visible", function()
        child.lua([=[
            _G.tab_called = false
            vim.keymap.set("i", "<Tab>", function()
                _G.tab_called = true
                return "TAB_CALLED"
            end, { expr = true })

            require("agentic.ui.file_picker").new(0)

            -- Set up buffer with multiple completion candidates
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello help helicopter", "" })
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
        ]=])

        -- Type partial word and trigger keyword completion
        child.type_keys("i", "hel", "<C-x><C-n>")

        -- Verify completion menu is actually visible
        assert.equal(1, child.fn.pumvisible())

        -- Now press Tab while menu is visible - should accept completion, not call fallback
        child.type_keys("<Tab>")

        assert.is_false(child.lua_get("_G.tab_called"))
    end)

    it("should call fallback for lazy-loaded global mapping", function()
        child.lua([=[
            _G.tab_called = false
            -- Initialize FilePicker BEFORE setting up any global mapping
            -- This simulates a plugin that loads after Agentic
            require("agentic.ui.file_picker").new(0)

            -- Now register a global Tab mapping (simulates lazy-loaded plugin)
            vim.keymap.set("i", "<Tab>", function()
                _G.tab_called = true
                return "LAZY_TAB_CALLED"
            end, { expr = true, desc = "Lazy-loaded Tab mapping" })

            vim.cmd([[execute "normal i\<Tab>"]])
        ]=])

        assert.is_true(child.lua_get("_G.tab_called"))
    end)

    it(
        "should handle vimscript expr mappings with proper keycode conversion",
        function()
            child.lua([=[
                vim.cmd([[
                    function! TestVimscriptExpr()
                        return "\t\t\<C-R>\<C-R>=123\<CR>\<CR>\<CR>"
                    endfunction
                    inoremap <expr> <Tab> TestVimscriptExpr()
                ]])

                require("agentic.ui.file_picker").new(0)
                vim.cmd([[silent execute "normal i\<Tab>"]])
            ]=])

            local content = child.lua_get(
                "table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')"
            )
            assert.equal("\t\t123\n\n", content)
        end
    )
end)
