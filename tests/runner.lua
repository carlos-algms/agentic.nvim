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

--- @return table reporter
local function make_reporter()
    return require("tests.plain_reporter").new({})
end

--- Run all tests
function M.run()
    run_with_exit(function()
        local MiniTest = require("mini.test")
        MiniTest.run({ execute = { reporter = make_reporter() } })
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
            execute = { reporter = make_reporter() },
        })
    end)
end

return M
