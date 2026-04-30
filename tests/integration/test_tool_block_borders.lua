local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local ChatWidget = require("agentic.ui.chat_widget")
local MessageWriter = require("agentic.ui.message_writer")
local ToolBlockBorder = require("agentic.ui.tool_block_border")

describe("Tool block borders", function()
    --- @type agentic.UserConfig.Folding|nil
    local saved_folding
    local saved_columns
    local saved_lines
    local tabpage
    --- @type agentic.ui.ChatWidget|nil
    local widget
    --- @type agentic.ui.MessageWriter|nil
    local writer

    before_each(function()
        saved_folding = vim.deepcopy(Config.folding)
        saved_columns = vim.o.columns
        saved_lines = vim.o.lines
        vim.o.columns = 80
        vim.o.lines = 24

        vim.cmd("tabnew")
        tabpage = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        if widget then
            widget:destroy()
            widget = nil
        end
        writer = nil

        if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
            pcall(vim.api.nvim_set_current_tabpage, tabpage)
            pcall(function()
                vim.cmd("tabclose!")
            end)
        end

        Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        vim.o.columns = saved_columns
        vim.o.lines = saved_lines
    end)

    --- @param folding_enabled boolean
    --- @param threshold integer
    local function open_chat(folding_enabled, threshold)
        Config.folding = {
            tool_calls = {
                enabled = folding_enabled,
                threshold = threshold,
            },
        }

        widget = ChatWidget:new(tabpage, function()
            return true
        end)
        widget:show({ focus_prompt = false })
        writer = MessageWriter:new(widget.buf_nrs.chat)
        writer:set_provider_name("Test")

        local chat_winid = widget.win_nrs.chat
        ---@cast chat_winid integer
        vim.wo[chat_winid].scrolloff = 0
        vim.api.nvim_win_set_width(chat_winid, 24)
    end

    --- @param tool_call_id string
    --- @param body string[]
    --- @return table<string, any> result
    local function write_block_and_sample(tool_call_id, body)
        if not writer or not widget then
            error("chat widget test setup did not run")
        end
        local current_writer = writer
        local current_widget = widget

        current_writer:write_tool_call_block({
            tool_call_id = tool_call_id,
            status = "completed",
            kind = "execute",
            argument = "sample",
            body = body,
        })

        local chat_winid = current_widget.win_nrs.chat
        ---@cast chat_winid integer
        local chat_bufnr = current_widget.buf_nrs.chat
        local tracker = current_writer.tool_call_blocks[tool_call_id]
        local pos = vim.api.nvim_buf_get_extmark_by_id(
            chat_bufnr,
            ToolBlockBorder.NS_TOOL_BLOCKS,
            tracker.extmark_id,
            { details = true }
        )

        local start_row = pos[1]
        local end_row = pos[3].end_row
        ---@cast end_row integer
        local top_pad_row = start_row + 1
        local body_row = start_row + 2
        local footer_row = end_row

        vim.api.nvim_set_current_win(chat_winid)
        vim.api.nvim_win_set_cursor(chat_winid, { start_row + 1, 0 })
        vim.cmd("normal! zt")
        vim.api.nvim__redraw({ win = chat_winid, valid = false, flush = true })

        local win_pos = vim.api.nvim_win_get_position(chat_winid)

        --- @param row integer
        --- @return integer offset
        local function offset_for(row)
            if row <= start_row then
                return 0
            end
            return vim.api.nvim_win_text_height(chat_winid, {
                start_row = start_row,
                end_row = row - 1,
            }).all
        end

        --- @param row integer
        --- @param virtnum integer
        --- @return string char
        local function cell(row, virtnum)
            local screen_row = win_pos[1] + offset_for(row) + virtnum
            local ok, inspected =
                pcall(vim.api.nvim__inspect_cell, 1, screen_row, win_pos[2])
            if not ok then
                vim.api.nvim__redraw({
                    win = chat_winid,
                    valid = false,
                    flush = true,
                })
                ok, inspected =
                    pcall(vim.api.nvim__inspect_cell, 1, screen_row, win_pos[2])
            end
            if not ok then
                return tostring(inspected)
            end
            return inspected[1]
        end

        return {
            header = cell(start_row, 0),
            top_pad = cell(top_pad_row, 0),
            body = cell(body_row, 0),
            body_wrap = cell(body_row, 1),
            body_height = vim.api.nvim_win_text_height(chat_winid, {
                start_row = body_row,
                end_row = body_row,
            }).all,
            footer = cell(footer_row, 0),
            fold_start = vim.fn.foldclosed(top_pad_row + 1),
            fold_end = vim.fn.foldclosedend(top_pad_row + 1),
        }
    end

    it(
        "renders borders on header, wrapped body continuations, and footer",
        function()
            open_chat(false, 10)

            local result = write_block_and_sample("wrap", {
                string.rep("long-output ", 5),
            })

            assert.equal("╭", result.header)
            assert.equal("│", result.body)
            assert.is_true(result.body_height > 1)
            assert.equal("│", result.body_wrap)
            assert.equal("╰", result.footer)
        end
    )

    it("renders the body border on a closed foldtext line", function()
        open_chat(true, 3)

        local result = write_block_and_sample("fold", {
            "L1",
            "L2",
            "L3",
            "L4",
            "L5",
            "L6",
        })

        assert.equal("╭", result.header)
        assert.equal("│", result.top_pad)
        assert.is_true(result.fold_start > 0)
        assert.is_true(result.fold_end >= result.fold_start)
        assert.equal("╰", result.footer)
    end)
end)
