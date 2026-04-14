-- Plain text reporter for mini.test (no ANSI colors)
-- Uses the same symbols and layout as MiniTest.gen_reporter.stdout
-- but strips all ANSI escape codes for non-interactive terminals and CI.
local M = {}

local ANSI_PATTERN = "\27%[[%d;]*m"

--- @param text string
--- @return string stripped
local function strip_ansi(text)
    local stripped = text:gsub(ANSI_PATTERN, "")
    return stripped
end

--- @param text string|string[]
local function write(text)
    if type(text) == "table" then
        io.stdout:write(strip_ansi(table.concat(text, "\n")))
    else
        io.stdout:write(strip_ansi(text))
    end
    io.flush()
end

--- @param cases table[]
--- @param group_depth number
--- @return table[] groups
local function compute_groups(cases, group_depth)
    return vim.tbl_map(function(c)
        local desc_trunc = vim.list_slice(c.desc, 1, group_depth)
        local name = table.concat(desc_trunc, " | ")
        return { name = name }
    end, cases)
end

local SYMBOLS = {
    ["Pass"] = "o",
    ["Pass with notes"] = "O",
    ["Fail"] = "x",
    ["Fail with notes"] = "X",
}

--- @param case table
--- @return string|nil symbol
local function case_symbol(case)
    local state = type(case.exec) == "table" and case.exec.state or nil
    return SYMBOLS[state]
end

--- @param case table
--- @return string stringid
local function case_to_stringid(case)
    return table.concat(case.desc, " | ")
end

--- @param items string[]
--- @param prefix string
--- @return string[]
local function add_prefix(items, prefix)
    return vim.tbl_map(function(item)
        return prefix .. item
    end, items)
end

--- @param cases table[]
--- @return boolean has_fails
local function has_fails(cases)
    for _, c in ipairs(cases) do
        if type(c.exec) == "table" and #c.exec.fails > 0 then
            return true
        end
    end
    return false
end

--- @param opts { group_depth?: number, quit_on_finish?: boolean }|nil
--- @return table reporter
function M.new(opts)
    opts = vim.tbl_deep_extend(
        "force",
        { group_depth = 1, quit_on_finish = true },
        opts or {}
    )

    local all_cases, all_groups, latest_group_name
    local reporter = {}

    reporter.start = function(cases)
        all_cases = cases
        all_groups = compute_groups(cases, opts.group_depth)

        local unique_names = {}
        for _, g in ipairs(all_groups) do
            unique_names[g.name] = true
        end
        local n_groups = #vim.tbl_keys(unique_names)

        write({
            string.format("Total number of cases: %s", #cases),
            string.format("Total number of groups: %s", n_groups),
            "",
        })
    end

    reporter.update = function(case_num)
        local cur_case = all_cases[case_num]
        local cur_group_name = all_groups[case_num].name

        if cur_group_name ~= latest_group_name then
            write("\n")
            write(cur_group_name)
            if cur_group_name ~= "" then
                write(": ")
            end
        end

        local symbol = case_symbol(cur_case)
        if symbol ~= nil then
            write(symbol)
        end

        latest_group_name = cur_group_name
    end

    reporter.finish = function()
        write("\n\n")

        local res = {}
        local n_fails, n_notes = 0, 0

        for _, c in ipairs(all_cases) do
            local stringid = case_to_stringid(c)
            local exec = c.exec == nil and { fails = {}, notes = {} } or c.exec

            local fail_prefix = string.format("FAIL in %s: ", stringid)
            local note_prefix = string.format("NOTE in %s: ", stringid)

            n_fails = n_fails + #exec.fails
            n_notes = n_notes + #exec.notes

            local cur_fails_notes = {}
            vim.list_extend(
                cur_fails_notes,
                add_prefix(exec.fails, fail_prefix)
            )
            vim.list_extend(
                cur_fails_notes,
                add_prefix(exec.notes, note_prefix)
            )

            if #cur_fails_notes > 0 then
                cur_fails_notes =
                    vim.split(table.concat(cur_fails_notes, "\n"), "\n")
                vim.list_extend(res, cur_fails_notes)
                table.insert(res, "")
            end
        end

        local header =
            string.format("Fails (%s) and Notes (%s)", n_fails, n_notes)
        table.insert(res, 1, header)

        write(res)
        write("\n")

        if not opts.quit_on_finish then
            return
        end
        local command =
            string.format("silent! %scquit", has_fails(all_cases) and 1 or 0)
        vim.cmd(command)
    end

    return reporter
end

return M
