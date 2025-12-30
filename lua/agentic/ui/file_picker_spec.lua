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

            -- lazy_repro is the temp folder where plugins are installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "lazy_repro/")
            -- .local is the folder where Neovim is installed during tests in CI
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.local/")

            local files_glob = picker:scan_files()

            assert.is_true(#files_glob > 0)
            assert.are.same(files_rg, files_glob)

            FilePicker.GLOB_EXCLUDE_PATTERNS = original_exclude_patterns
        end)
    end)
end)

describe("FilePicker keymap fallback", function()
    local bufnr
    local tab_called
    local Config
    local original_pumvisible

    local pum_return_value = 0

    before_each(function()
        Config = require("agentic.config")
        Config.file_picker.enabled = true

        original_pumvisible = vim.fn.pumvisible

        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.pumvisible = function() -- luacheck: ignore
            return pum_return_value
        end

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)

        tab_called = false
    end)

    after_each(function()
        pum_return_value = 0

        vim.fn.pumvisible = original_pumvisible -- luacheck: ignore

        pcall(vim.keymap.del, "i", "<Tab>")
        pcall(vim.keymap.del, "i", "<CR>")

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it(
        "should call fallback Tab mapping when completion menu not visible",
        function()
            -- Set up a pre-existing GLOBAL Tab mapping (simulates copilot.vim)
            vim.keymap.set("i", "<Tab>", function()
                tab_called = true
                return "TAB_CALLED"
            end, {
                expr = true,
                desc = "Test Tab mapping",
            })

            FilePicker.new(bufnr)

            vim.cmd([[execute "normal i\<Tab>"]])

            assert.is_true(tab_called)
        end
    )

    it(
        "should call fallback CR mapping when completion menu not visible",
        function()
            local cr_called = false

            -- Set up a pre-existing GLOBAL CR mapping
            vim.keymap.set("i", "<CR>", function()
                cr_called = true
                return "CR_CALLED"
            end, {
                expr = true,
            })

            FilePicker.new(bufnr)

            vim.cmd([[execute "normal i\<CR>"]])

            assert.is_true(cr_called)
        end
    )

    it("should NOT call fallback when completion menu is visible", function()
        vim.keymap.set("i", "<Tab>", function()
            tab_called = true
            return "TAB_CALLED"
        end, {
            expr = true,
        })

        FilePicker.new(bufnr)

        pum_return_value = 1

        vim.cmd([[execute "normal i\<Tab>"]])

        assert.is_false(tab_called)
    end)

    it("should call fallback for lazy-loaded global mapping", function()
        -- Initialize FilePicker BEFORE setting up any global mapping
        -- This simulates a plugin that loads after Agentic
        FilePicker.new(bufnr)

        -- Now register a global Tab mapping (simulates lazy-loaded plugin)
        vim.keymap.set("i", "<Tab>", function()
            tab_called = true
            return "LAZY_TAB_CALLED"
        end, {
            expr = true,
            desc = "Lazy-loaded Tab mapping",
        })

        vim.cmd([[execute "normal i\<Tab>"]])

        assert.is_true(tab_called)
    end)

    it(
        "should handle vimscript expr mappings with proper keycode conversion",
        function()
            -- Simulates copilot.vim: expr mapping returns complex keycodes
            -- 2 tabs, expression register inserting "123", then 2 newlines
            vim.cmd([[
                function! TestVimscriptExpr()
                    return "\t\t\<C-R>\<C-R>=123\<CR>\<CR>\<CR>"
                endfunction
                inoremap <expr> <Tab> TestVimscriptExpr()
            ]])

            FilePicker.new(bufnr)

            -- this one has silence because of the vimScript mapping
            vim.cmd([[silent execute "normal i\<Tab>"]])

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local content = table.concat(lines, "\n")
            assert.equal("\t\t123\n\n", content)
        end
    )
end)
