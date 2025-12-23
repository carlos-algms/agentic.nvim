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
        it("should return same file count for all commands", function()
            local file_counts = {}

            -- Test rg
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            file_counts.rg = #picker:scan_files()

            -- Test fd
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = original_cmd_fd
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            file_counts.fd = #picker:scan_files()

            -- Test git
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = original_cmd_git
            file_counts.git = #picker:scan_files()

            -- All commands should return more than 0 files
            assert.is_true(file_counts.rg > 0)
            assert.is_true(file_counts.fd > 0)
            assert.is_true(file_counts.git > 0)

            -- All commands should return the same count
            assert.are.equal(
                file_counts.rg,
                file_counts.fd,
                string.format(
                    "rg and fd counts don't match: %s",
                    vim.inspect(file_counts)
                )
            )
            assert.are.equal(
                file_counts.fd,
                file_counts.git,
                string.format(
                    "fd and git counts don't match: %s",
                    vim.inspect(file_counts)
                )
            )
        end)
    end)
end)
