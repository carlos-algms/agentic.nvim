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
            -- TODO: Remove vim.diff after Neovim 0.12 is released, and became the minimum requirement
            --- @diagnostic disable-next-line: deprecated
            local diff_fn = vim.text and vim.text.diff or vim.diff

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

            -- Extract file paths (remove @ prefix) for comparison
            local paths_rg = vim.tbl_map(function(f)
                return f.word:sub(2)
            end, files_rg)
            local paths_fd = vim.tbl_map(function(f)
                return f.word:sub(2)
            end, files_fd)
            local paths_git = vim.tbl_map(function(f)
                return f.word:sub(2)
            end, files_git)

            -- Compare rg vs fd using vim.diff
            local diff_rg_fd = diff_fn(
                table.concat(paths_rg, "\n"),
                table.concat(paths_fd, "\n"),
                { result_type = "indices" }
            )
            assert.are.same({}, diff_rg_fd, "rg and fd return different files")

            -- Compare fd vs git using vim.diff
            local diff_fd_git = diff_fn(
                table.concat(paths_fd, "\n"),
                table.concat(paths_git, "\n"),
                { result_type = "indices" }
            )
            assert.are.same(
                {},
                diff_fd_git,
                "fd and git return different files"
            )
        end)
    end)
end)
