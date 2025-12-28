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

            local system_calls = {}
            local call_count = 0

            ---@diagnostic disable-next-line: duplicate-set-field -- we must mock it to force specific behavior
            vim.fn.system = function(cmd) -- luacheck: ignore
                call_count = call_count + 1
                table.insert(system_calls, cmd)

                if call_count == 1 then
                    -- First command fails
                    return original_system("false")
                else
                    -- Second command succeeds
                    original_system("true")
                    return "file1.lua\nfile2.lua\nfile3.lua\n"
                end
            end

            local files = picker:scan_files()

            -- Should have called system exactly 2 times (first fails, second succeeds)
            assert.are.equal(2, #system_calls)
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
            assert.are.equal(
                #files_rg,
                #files_fd,
                "rg and fd counts don't match"
            )
            assert.are.equal(
                #files_fd,
                #files_git,
                "fd and git counts don't match"
            )

            assert.are.same(
                files_rg,
                files_fd,
                "rg and fd return different files"
            )
            assert.are.same(
                files_fd,
                files_git,
                "fd and git return different files"
            )
        end)

        it("should use glob fallback when all commands fail", function()
            local original_exclude_patterns = FilePicker.GLOB_EXCLUDE_PATTERNS

            -- First, get files from rg for comparison
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = picker:scan_files()

            -- Disable all commands to force glob fallback
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"

            -- Add lazy_repro to exclude patterns for this test
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "lazy_repro/")

            local files_glob = picker:scan_files()

            -- Should return files using glob fallback
            assert.is_true(#files_glob > 0)

            -- Compare rg vs glob
            assert.are.same(
                files_rg,
                files_glob,
                "rg and glob return different files"
            )

            -- Restore original exclude patterns
            FilePicker.GLOB_EXCLUDE_PATTERNS = original_exclude_patterns
        end)
    end)
end)

describe("FilePicker keymap fallback", function()
    local bufnr
    local tab_called
    local cr_called
    local Config
    local original_pumvisible

    before_each(function()
        Config = require("agentic.config")
        Config.file_picker.enabled = true

        -- Save original pumvisible function
        original_pumvisible = vim.fn.pumvisible

        bufnr = vim.api.nvim_create_buf(false, true)
        tab_called = false
        cr_called = false
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end

        pcall(vim.keymap.del, "i", "<Tab>")
        pcall(vim.keymap.del, "i", "<CR>")

        vim.fn.pumvisible = original_pumvisible -- luacheck: ignore
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

            -- Verify the test mapping was set (global mapping)
            local test_mapping = vim.fn.maparg("<Tab>", "i", false, true)
            assert.is_not_nil(test_mapping.rhs or test_mapping.callback)

            FilePicker.new(bufnr)

            -- Get the file picker's Tab mapping
            local mappings = vim.api.nvim_buf_get_keymap(bufnr, "i")
            local tab_mapping = nil --- @type vim.api.keyset.get_keymap

            for _, map in ipairs(mappings) do
                if
                    map.lhs == "<Tab>"
                    and map.desc
                    and map.desc:match("%[agentic%-fallback%]")
                then
                    tab_mapping = map
                    break
                end
            end

            assert.is_not_nil(tab_mapping)
            assert.is_not_nil(tab_mapping.callback)

            -- Simulate Tab press with completion menu NOT visible
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.pumvisible = function() -- luacheck: ignore
                return 0
            end

            -- Call the mapping callback
            local result = tab_mapping.callback()

            assert.is_true(tab_called)
            assert.equal("TAB_CALLED", result)
        end
    )

    it(
        "should call fallback CR mapping when completion menu not visible",
        function()
            -- Set up a pre-existing GLOBAL CR mapping
            vim.keymap.set("i", "<CR>", function()
                cr_called = true
                return "CR_CALLED"
            end, {
                expr = true,
            })

            FilePicker.new(bufnr)

            local mappings = vim.api.nvim_buf_get_keymap(bufnr, "i")
            local cr_mapping = nil --- @type vim.api.keyset.get_keymap

            for _, map in ipairs(mappings) do
                if
                    map.lhs == "<CR>"
                    and map.desc
                    and map.desc:match("%[agentic%-fallback%]")
                then
                    cr_mapping = map
                    break
                end
            end

            assert.is_not_nil(cr_mapping)
            assert.is_not_nil(cr_mapping.callback)

            -- Simulate CR press with completion menu NOT visible
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.pumvisible = function() -- luacheck: ignore
                return 0
            end

            local result = cr_mapping.callback()

            -- Should have called the fallback
            assert.is_true(cr_called)
            assert.equal("CR_CALLED", result)
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

        local mappings = vim.api.nvim_buf_get_keymap(bufnr, "i")
        local tab_mapping = nil --- @type vim.api.keyset.get_keymap

        for _, map in ipairs(mappings) do
            if
                map.lhs == "<Tab>"
                and map.desc
                and map.desc:match("%[agentic%-fallback%]")
            then
                tab_mapping = map
                break
            end
        end

        -- Simulate Tab press with completion menu VISIBLE
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.pumvisible = function() -- luacheck: ignore
            return 1
        end

        local result = tab_mapping.callback()

        -- Should return completion accept sequence, NOT call fallback
        assert.is_false(tab_called)
        assert.equal("<C-y> ", result)
    end)

    it("should call fallback for lazy-loaded global mapping", function()
        -- Initialize FilePicker BEFORE setting up any global mapping
        -- This simulates a plugin that loads after agentic
        FilePicker.new(bufnr)

        -- Now register a global Tab mapping (simulates lazy-loaded copilot.vim)
        vim.keymap.set("i", "<Tab>", function()
            tab_called = true
            return "LAZY_TAB_CALLED"
        end, {
            expr = true,
            desc = "Lazy-loaded Tab mapping",
        })

        -- Get the file picker's Tab mapping
        local mappings = vim.api.nvim_buf_get_keymap(bufnr, "i")
        local tab_mapping = nil --- @type vim.api.keyset.get_keymap
        for _, map in ipairs(mappings) do
            if
                map.lhs == "<Tab>"
                and map.desc
                and map.desc:match("%[agentic%-fallback%]")
            then
                tab_mapping = map
                break
            end
        end

        assert.is_not_nil(tab_mapping)

        -- Simulate Tab press with completion menu NOT visible
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.pumvisible = function() -- luacheck: ignore
            return 0
        end

        local result = tab_mapping.callback()

        assert.is_true(tab_called)
        assert.equal("LAZY_TAB_CALLED", result)
    end)
end)
