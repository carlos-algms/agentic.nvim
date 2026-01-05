--- @class agentic.ui.ToolCallDiff.DiffBlock
--- @field start_line integer
--- @field end_line integer
--- @field old_lines string[]
--- @field new_lines string[]

--- @class agentic.ui.ToolCallDiff.Hunk
--- @field old_lines string[]
--- @field new_lines string[]

--- @class agentic.ui.ToolCallDiff
local M = {}

local TextMatcher = require("agentic.utils.text_matcher")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- @param path string
--- @param oldText string[]
--- @param newText string[]
--- @param replace_all? boolean
--- @return agentic.ui.ToolCallDiff.DiffBlock[] diff_blocks
function M.extract_diff_blocks(path, oldText, newText, replace_all)
    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local diff_blocks = {}

    if not path or not newText then
        return diff_blocks
    end

    local old_lines = M._normalize_text_to_lines(oldText)
    local new_lines = M._normalize_text_to_lines(newText)

    local is_new_file = #old_lines == 0
        or (#old_lines == 1 and old_lines[1] == "")

    if is_new_file then
        table.insert(diff_blocks, M._create_new_file_diff_block(new_lines))
    else
        local abs_path = FileSystem.to_absolute_path(path)
        local file_lines = FileSystem.read_from_buffer_or_disk(abs_path) or {}

        local matches = TextMatcher.find_all_matches(file_lines, old_lines)

        if #matches > 0 then
            local limit = replace_all and #matches or 1
            for i = 1, limit do
                table.insert(diff_blocks, {
                    start_line = matches[i].start_line,
                    end_line = matches[i].end_line,
                    old_lines = old_lines,
                    new_lines = new_lines,
                })
            end
        else
            Logger.debug("[ACP diff] Failed to locate diff", { path = path })
        end
    end

    diff_blocks = M._minimize_diff_blocks(diff_blocks)

    return diff_blocks
end

--- Minimize diff blocks by removing unchanged lines using vim.diff
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @return agentic.ui.ToolCallDiff.DiffBlock[]
function M._minimize_diff_blocks(diff_blocks)
    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local minimized = {}

    for _, diff_block in ipairs(diff_blocks) do
        if #diff_block.old_lines == 1 and #diff_block.new_lines == 1 then
            table.insert(minimized, diff_block)
        else
            local old_string = table.concat(diff_block.old_lines, "\n")
            local new_string = table.concat(diff_block.new_lines, "\n")

            -- vim.diff was renamed to vim.text.diff (identical signature, just namespace move)
            -- Fallback needed for backward compatibility with Neovim < 0.12
            --- @type fun(a: string, b: string, opts: table): integer[][]
            --- @diagnostic disable-next-line: deprecated
            local diff_fn = vim.text and vim.text.diff or vim.diff

            local patch = diff_fn(old_string, new_string, {
                algorithm = "histogram",
                result_type = "indices",
                ctxlen = 0,
            })

            if #patch > 0 then
                for _, hunk in ipairs(patch) do
                    local start_a, count_a, start_b, count_b = unpack(hunk)

                    --- @type agentic.ui.ToolCallDiff.DiffBlock
                    local minimized_block = {
                        start_line = 0,
                        end_line = 0,
                        old_lines = {},
                        new_lines = {},
                    }

                    if count_a > 0 then
                        local end_a = math.min(
                            start_a + count_a - 1,
                            #diff_block.old_lines
                        )
                        minimized_block.old_lines =
                            vim.list_slice(diff_block.old_lines, start_a, end_a)
                        minimized_block.start_line = diff_block.start_line
                            + start_a
                            - 1
                        minimized_block.end_line = minimized_block.start_line
                            + count_a
                            - 1
                    else
                        minimized_block.start_line = diff_block.start_line
                            + start_a
                        minimized_block.end_line = minimized_block.start_line
                            - 1
                    end

                    if count_b > 0 then
                        local end_b = math.min(
                            start_b + count_b - 1,
                            #diff_block.new_lines
                        )
                        minimized_block.new_lines =
                            vim.list_slice(diff_block.new_lines, start_b, end_b)
                    end

                    table.insert(minimized, minimized_block)
                end
            else
                if old_string ~= new_string then
                    table.insert(minimized, diff_block)
                end
            end
        end
    end

    table.sort(minimized, function(a, b)
        return a.start_line < b.start_line
    end)

    return minimized
end

--- Create a diff block for a new file
--- @param new_lines string[]
--- @return agentic.ui.ToolCallDiff.DiffBlock
function M._create_new_file_diff_block(new_lines)
    local line_count = #new_lines

    --- @type agentic.ui.ToolCallDiff.DiffBlock
    local block = {
        start_line = 1,
        end_line = line_count > 0 and line_count or 1,
        old_lines = {},
        new_lines = new_lines,
    }

    return block
end

--- Normalize text to lines array, handling nil and vim.NIL
--- @param text? string|string[]
--- @return string[]
function M._normalize_text_to_lines(text)
    if not text or text == "" or text == vim.NIL then
        return {}
    end

    if type(text) == "string" then
        return vim.split(text, "\n")
    end

    return text
end

--- Minimize diff to only show changed hunks (content only, no file positioning)
--- @param old_lines string[]
--- @param new_lines string[]
--- @return agentic.ui.ToolCallDiff.Hunk[] hunks
function M.minimize_diff(old_lines, new_lines)
    if #old_lines == 0 then
        return { { old_lines = {}, new_lines = new_lines } }
    end

    if #old_lines == 1 and #new_lines == 1 then
        return { { old_lines = old_lines, new_lines = new_lines } }
    end

    local old_string = table.concat(old_lines, "\n")
    local new_string = table.concat(new_lines, "\n")

    --- @type fun(a: string, b: string, opts: table): integer[][]
    --- @diagnostic disable-next-line: deprecated
    local diff_fn = vim.text and vim.text.diff or vim.diff

    local patch = diff_fn(old_string, new_string, {
        algorithm = "histogram",
        result_type = "indices",
        ctxlen = 0,
    })

    if #patch == 0 then
        if old_string ~= new_string then
            return { { old_lines = old_lines, new_lines = new_lines } }
        end
        return {}
    end

    --- @type agentic.ui.ToolCallDiff.Hunk[]
    local hunks = {}

    for _, hunk in ipairs(patch) do
        local start_a, count_a, start_b, count_b = unpack(hunk)

        local old = {}
        local new = {}

        if count_a > 0 then
            local end_a = math.min(start_a + count_a - 1, #old_lines)
            old = vim.list_slice(old_lines, start_a, end_a)
        end

        if count_b > 0 then
            local end_b = math.min(start_b + count_b - 1, #new_lines)
            new = vim.list_slice(new_lines, start_b, end_b)
        end

        table.insert(hunks, { old_lines = old, new_lines = new })
    end

    return hunks
end

return M
