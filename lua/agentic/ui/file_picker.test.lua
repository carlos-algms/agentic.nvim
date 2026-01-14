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
        picker = FilePicker:new(vim.api.nvim_create_buf(false, true)) --[[@as agentic.ui.FilePicker]]
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

    --- Setup a tracking expr keymap using vimscript (fully typed, no child.lua needed)
    --- @param key string The key to map (e.g., "<Tab>", "<CR>")
    --- @param global_name string The global variable name (g:) to track calls
    local function setup_tracking_keymap(key, global_name)
        child.g[global_name] = false
        -- vimscript expr: execute() returns "" on success, concat with return value
        local rhs = ("execute('let g:%s = v:true') .. '%s_CALLED'"):format(
            global_name,
            key:upper():gsub("[<>]", "")
        )
        child.api.nvim_set_keymap("i", key, rhs, { expr = true })
    end

    --- Load FilePicker in child process to void polluting main test env
    local function load_file_picker()
        child.lua([[require("agentic.ui.file_picker"):new(0)]])
    end

    --- Execute insert mode key via normal command
    --- @param key string
    local function execute_insert_key(key)
        child.cmd(([[silent execute "normal i\%s"]]):format(key))
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it(
        "should call fallback Tab mapping when completion menu not visible",
        function()
            local prop_name = "tab_called"
            setup_tracking_keymap("<Tab>", prop_name)
            load_file_picker()
            execute_insert_key("<Tab>")

            assert.is_true(child.g[prop_name])
        end
    )

    it(
        "should call fallback CR mapping when completion menu not visible",
        function()
            local prop_name = "cr_called"
            setup_tracking_keymap("<CR>", prop_name)
            load_file_picker()
            execute_insert_key("<CR>")

            assert.is_true(child.g[prop_name])
        end
    )

    it("should NOT call fallback when completion menu is visible", function()
        local prop_name = "tab_called"
        setup_tracking_keymap("<Tab>", prop_name)
        load_file_picker()

        -- Set up buffer with multiple completion candidates
        child.api.nvim_buf_set_lines(
            0,
            0,
            -1,
            false,
            { "hello help helicopter", "" }
        )
        child.api.nvim_win_set_cursor(0, { 2, 0 })

        -- Type partial word and trigger keyword completion
        child.type_keys("i", "hel", "<C-x><C-n>")

        -- Verify completion menu is actually visible
        assert.equal(1, child.fn.pumvisible())

        -- Now press Tab while menu is visible - should accept completion, not call fallback
        child.type_keys("<Tab>")

        assert.is_false(child.g[prop_name])
    end)

    it("should call fallback for lazy-loaded global mapping", function()
        local prop_name = "tab_called"
        child.g[prop_name] = false
        -- Initialize FilePicker BEFORE setting up any global mapping
        -- This simulates a plugin that loads after Agentic
        load_file_picker()

        -- Now register a global Tab mapping (simulates lazy-loaded plugin)
        setup_tracking_keymap("<Tab>", prop_name)
        execute_insert_key("<Tab>")

        assert.is_true(child.g[prop_name])
    end)

    it(
        "should handle vimscript expr mappings with proper keycode conversion",
        function()
            child.cmd([[
                function! TestVimscriptExpr()
                    return "\t\t\<C-R>\<C-R>=123\<CR>\<CR>\<CR>"
                endfunction
                inoremap <expr> <Tab> TestVimscriptExpr()
            ]])

            load_file_picker()
            execute_insert_key("<Tab>")

            local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
            assert.equal("\t\t123\n\n", table.concat(lines, "\n"))
        end
    )
end)
