-- Test runner with error handling to prevent hanging
local M = {}

local function exit_with_error(msg)
    io.stderr:write("Error: " .. tostring(msg) .. "\n")
    vim.cmd("cquit 1")
end

local function exit_success()
    vim.cmd("qall!")
end

--- @param fn function
local function run_with_exit(fn)
    local ok, err = pcall(fn)
    if ok then
        exit_success()
    else
        exit_with_error(err)
    end
end

--- Run all tests
--- @param opts? { verbose?: boolean }
function M.run(opts)
    opts = opts or {}
    run_with_exit(function()
        local MiniTest = require("mini.test")
        local run_opts = opts.verbose
                and { execute = { reporter = MiniTest.gen_reporter.stdout({}) } }
            or {}
        MiniTest.run(run_opts)
    end)
end

--- Run a specific test file
--- @param file string
function M.run_file(file)
    if not file or file == "" then
        exit_with_error("No file specified")
    end

    if not vim.uv.fs_stat(file) then
        exit_with_error("File not found: " .. file)
    end

    run_with_exit(function()
        local MiniTest = require("mini.test")
        MiniTest.run_file(file, {
            execute = { reporter = MiniTest.gen_reporter.stdout({}) },
        })
    end)
end

return M
