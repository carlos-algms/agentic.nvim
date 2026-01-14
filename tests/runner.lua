-- Test runner with error handling to prevent hanging
local M = {}

local function exit_with_error(msg)
    io.stderr:write("Error: " .. tostring(msg) .. "\n")
    vim.cmd("cquit 1")
end

local function exit_success()
    vim.cmd("qall!")
end

--- Run all tests
--- @param opts? { verbose?: boolean }
function M.run(opts)
    opts = opts or {}

    local ok, err = pcall(function()
        local MiniTest = require("mini.test")
        local run_opts = {}
        if opts.verbose then
            run_opts.execute = {
                reporter = MiniTest.gen_reporter.stdout({}),
            }
        end
        MiniTest.run(run_opts)
    end)

    if not ok then
        exit_with_error(err)
    else
        exit_success()
    end
end

--- Run a specific test file
--- @param file string
function M.run_file(file)
    if not file or file == "" then
        exit_with_error("No file specified")
        return
    end

    local stat = vim.uv.fs_stat(file)
    if not stat then
        exit_with_error("File not found: " .. file)
        return
    end

    local ok, err = pcall(function()
        local MiniTest = require("mini.test")
        MiniTest.run_file(file, {
            execute = {
                reporter = MiniTest.gen_reporter.stdout({}),
            },
        })
    end)

    if not ok then
        exit_with_error(err)
    else
        exit_success()
    end
end

return M
