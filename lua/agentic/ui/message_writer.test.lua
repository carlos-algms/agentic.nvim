--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        if writer then
            writer:destroy()
        end
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @return string[]
    local function get_all_lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    --- @return string
    local function get_all_content()
        return table.concat(get_all_lines(), "\n")
    end

    --- @param pattern string
    --- @return boolean
    local function content_has(pattern)
        for _, line in ipairs(get_all_lines()) do
            if line:find(pattern) then
                return true
            end
        end
        return false
    end

    --- @param pattern string
    --- @return integer
    local function count_matching_lines(pattern)
        local count = 0
        for _, line in ipairs(get_all_lines()) do
            if line:match(pattern) then
                count = count + 1
            end
        end
        return count
    end

    --- @param text string
    --- @param session_update string|nil
    --- @return agentic.acp.SessionUpdateMessage
    local function make_update(text, session_update)
        return {
            sessionUpdate = session_update or "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_thought_update(text)
        return {
            sessionUpdate = "agent_thought_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    local NS_THINKING = vim.api.nvim_create_namespace("agentic_thinking")

    --- @return vim.api.keyset.get_extmark_item[]
    local function get_thinking_extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            NS_THINKING,
            0,
            -1,
            { details = true }
        )
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check cursor across tabpages", function()
            setup_buffer(50, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)
    end)

    describe("on_content_changed callback", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("stores and fires callback via set_on_content_changed", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(1)
        end)

        it("clears callback when set to nil", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])
            writer:set_on_content_changed(nil)

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(0)
        end)

        it(
            "fires callback for each write method that produces content",
            function()
                local block = make_tool_call_block("cb-setup", "pending")
                writer:write_tool_call_block(block)

                local callback_spy = spy.new(function() end)
                writer:set_on_content_changed(callback_spy --[[@as function]])

                writer:write_message(make_update("hello"))
                writer:write_message_chunk(make_update("chunk"))
                writer:write_tool_call_block(
                    make_tool_call_block("cb-1", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "cb-setup",
                    status = "completed",
                    body = { "done" },
                })

                assert.spy(callback_spy).was.called(4)
            end
        )

        it("does not fire callback when content is empty", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:write_message(make_update(""))
            writer:write_message_chunk(make_update(""))

            assert.spy(callback_spy).was.called(0)
        end)
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        local read_stub
        local path_stub

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
            read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
            path_stub = spy.stub(FileSystem, "to_absolute_path")
            path_stub:invokes(function(path)
                return path
            end)
        end)

        after_each(function()
            read_stub:revert()
            path_stub:revert()
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
        end)
    end)

    describe("sender header tracking", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("writes user header on first user_message_chunk", function()
            writer:write_message_chunk(
                make_update("hello", "user_message_chunk")
            )

            assert.equal(
                1,
                count_matching_lines("^## .* User %- %d%d%d%d%-%d%d%-%d%d")
            )
        end)

        it("writes agent header on first agent_message_chunk", function()
            writer:set_provider_name("TestAgent")
            writer:write_message_chunk(
                make_update("response", "agent_message_chunk")
            )

            assert.equal(1, count_matching_lines("### .* Agent %- TestAgent"))
        end)

        it("skips header for consecutive same sender", function()
            writer:write_message_chunk(
                make_update("msg1", "user_message_chunk")
            )
            writer:write_message_chunk(
                make_update("msg2", "user_message_chunk")
            )

            assert.equal(1, count_matching_lines("^## .* User"))
        end)

        it("writes agent header before tool call block", function()
            writer:set_provider_name("TestAgent")
            writer:write_message_chunk(
                make_update("question", "user_message_chunk")
            )
            writer:write_tool_call_block(
                make_tool_call_block("tc-1", "pending")
            )

            local lines = get_all_lines()
            local user_idx, agent_idx
            for i, line in ipairs(lines) do
                if line:match("^## .* User") then
                    user_idx = i
                end
                if line:match("### .* Agent %- TestAgent") then
                    agent_idx = i
                end
            end
            assert.is_not_nil(user_idx)
            assert.is_not_nil(agent_idx)
            assert.is_true(agent_idx > user_idx)
        end)

        it("omits timestamp when restoring", function()
            writer:write_restoring_message(
                make_update("restored", "user_message_chunk")
            )

            assert.equal(1, count_matching_lines("^## .* User$"))
            assert.equal(0, count_matching_lines("^## .* User %- %d%d%d%d"))
        end)

        it("skips header for plan updates", function()
            writer:_maybe_write_sender_header("plan")

            assert.equal(0, count_matching_lines("Agent"))
            assert.equal(0, count_matching_lines("User"))
        end)

        it(
            "writes agent header for thought chunk if last sender was user",
            function()
                writer:set_provider_name("TestAgent")
                writer:write_message_chunk(
                    make_update("question", "user_message_chunk")
                )
                writer:write_message_chunk(
                    make_update("thinking...", "agent_thought_chunk")
                )

                assert.equal(
                    1,
                    count_matching_lines("### .* Agent %- TestAgent")
                )
            end
        )
    end)

    describe("replay_history_messages", function()
        it("replays messages with correct provider-specific headers", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "user",
                    text = "hello",
                    timestamp = 1000,
                    provider_name = "Claude",
                },
                {
                    type = "agent",
                    text = "from claude",
                    provider_name = "Claude",
                },
                {
                    type = "user",
                    text = "another question",
                    provider_name = "Claude",
                },
                {
                    type = "agent",
                    text = "from gemini",
                    provider_name = "Gemini",
                },
            }

            writer:replay_history_messages(messages)

            local content = get_all_content()
            assert.truthy(content:match("## .* User"))
            assert.truthy(content:match("hello"))
            assert.truthy(content:match("### .* Agent %- Claude"))
            assert.truthy(content:match("from claude"))
            assert.truthy(content:match("### .* Agent %- Gemini"))
            assert.truthy(content:match("from gemini"))
        end)

        it("restores current provider after replay", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "agent",
                    text = "old message",
                    provider_name = "Gemini",
                },
            }

            writer:replay_history_messages(messages)

            assert.equal("Claude", writer._provider_name)
        end)

        it("handles thought chunk messages with highlighting", function()
            writer:set_provider_name("Claude")

            writer:replay_history_messages({
                {
                    type = "thought",
                    text = "thinking about this",
                    provider_name = "Claude",
                },
            })

            assert.is_true(content_has("🧠 thinking about this"))

            local extmarks = get_thinking_extmarks()
            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            assert.equal("AgenticThinking", details.hl_group)
            assert.is_true(details.hl_eol)
            assert.is_true(details.end_col > 0)
        end)

        it("handles tool_call messages", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "tool_call",
                    tool_call_id = "tc-1",
                    kind = "read",
                    file_path = "test.txt",
                    status = "completed",
                    body = { "file content" },
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            assert.is_not_nil(writer.tool_call_blocks["tc-1"])
            assert.truthy(get_all_content():match("read"))
        end)

        it("formats unformatted single-line JSON body on replay", function()
            writer:set_provider_name("Claude")

            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "tool_call",
                    tool_call_id = "tc-json",
                    kind = "fetch",
                    argument = "MCP",
                    status = "completed",
                    body = { json_text },
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            local tracker = writer.tool_call_blocks["tc-json"]
            assert.is_not_nil(tracker)
            assert.is_true(#tracker.body > 1)
        end)

        it(
            "replay thought extmark covers content lines, not trailing blank",
            function()
                writer:replay_history_messages({
                    {
                        type = "thought",
                        text = "line one\nline two",
                        provider_name = "Claude",
                    },
                })

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local start_row = extmarks[1][2]
                local details = extmarks[1][4] --- @type table
                local end_row = details.end_row

                local start_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    start_row,
                    start_row + 1,
                    false
                )[1]
                assert.truthy(start_line_text:find("🧠"))

                local end_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    end_row,
                    end_row + 1,
                    false
                )[1]
                assert.truthy(end_line_text:find("line two"))

                assert.equal(#end_line_text, details.end_col)
            end
        )
    end)

    describe("thinking block highlighting", function()
        it(
            "creates extmark with correct properties on first thought chunk",
            function()
                writer:write_message_chunk(make_thought_update("thinking"))

                assert.is_not_nil(writer._thinking_extmark_id)
                assert.is_not_nil(writer._thinking_start_line)

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local details = extmarks[1][4] --- @type table
                assert.equal("AgenticThinking", details.hl_group)
                assert.is_true(details.hl_eol)
                assert.is_true(details.end_col > 0)

                assert.is_true(content_has("🧠 thinking"))
            end
        )

        it("does not prepend emoji on subsequent thought chunks", function()
            writer:write_message_chunk(make_thought_update("first"))
            writer:write_message_chunk(make_thought_update(" second"))

            assert.equal(1, count_matching_lines("🧠"))
        end)

        it("updates extmark end_row and end_col as content grows", function()
            writer:write_message_chunk(make_thought_update("line1"))
            local initial_end = writer._thinking_end_line

            writer:write_message_chunk(make_thought_update("\nline2"))
            assert.is_true(writer._thinking_end_line > initial_end)

            local extmarks = get_thinking_extmarks()
            assert.equal(1, #extmarks)
            assert.equal(writer._thinking_end_line, extmarks[1][4].end_row)

            writer._thinking_extmark_id = nil
            writer._thinking_start_line = nil
            writer._thinking_end_line = nil
            writer._scroll_scheduled = false

            writer:write_message_chunk(make_thought_update("start"))
            local before = get_thinking_extmarks()
            local end_col_before = before[2][4].end_col

            writer:write_message_chunk(make_thought_update(" more text"))
            local after = get_thinking_extmarks()
            local end_col_after = after[2][4].end_col

            assert.is_true(end_col_after > end_col_before)
        end)

        it("stops updating extmark when switching to message", function()
            writer:write_message_chunk(make_thought_update("thinking"))
            assert.is_not_nil(writer._thinking_extmark_id)

            writer:write_message_chunk(make_update("response"))

            assert.is_nil(writer._thinking_extmark_id)
            assert.equal(1, #get_thinking_extmarks())
        end)

        it(
            "starts extmark at thought content line, not blank separator after header",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "question" },
                })

                writer:write_message_chunk(make_thought_update("deep thinking"))

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local start_row = extmarks[1][2]

                local start_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    start_row,
                    start_row + 1,
                    false
                )[1]
                assert.truthy(start_line_text:find("🧠"))
            end
        )

        it(
            "clears thinking state on reset_sender_tracking, write_tool_call_block, and write_message",
            function()
                local triggers = {
                    function()
                        writer:reset_sender_tracking()
                    end,
                    function()
                        writer:write_tool_call_block(
                            make_tool_call_block("tc-clear-1", "pending")
                        )
                    end,
                    function()
                        writer:write_message(make_update("full response"))
                    end,
                }

                for _, trigger in ipairs(triggers) do
                    writer:write_message_chunk(
                        make_thought_update("thinking...")
                    )
                    assert.is_not_nil(writer._thinking_extmark_id)

                    trigger()

                    assert.is_nil(writer._thinking_extmark_id)
                    assert.is_nil(writer._thinking_start_line)
                    assert.is_nil(writer._thinking_end_line)
                end
            end
        )

        it("creates a new extmark for thought after tool call block", function()
            writer:write_message_chunk(make_thought_update("first thought"))
            local first_extmark_id = writer._thinking_extmark_id
            assert.is_not_nil(first_extmark_id)

            writer:write_tool_call_block(
                make_tool_call_block("tc-between-1", "pending")
            )
            writer:write_message_chunk(make_thought_update("second thought"))

            assert.is_not_nil(writer._thinking_extmark_id)
            assert.is_true(writer._thinking_extmark_id ~= first_extmark_id)

            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
            assert.equal(2, #extmarks)
        end)
    end)

    describe("tool call body JSON formatting", function()
        it("formats single-line JSON body when writing the block", function()
            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            local block =
                make_tool_call_block("json-1", "completed", { json_text })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-1"]
            assert.is_not_nil(tracker)
            assert.is_true(#tracker.body > 1)
        end)

        it(
            "leaves placeholder text untouched and formats only JSON segments on update",
            function()
                local placeholder = "I'm going to fetch this"
                local long_value = string.rep("v", 100)
                local json_text = '{"key":"' .. long_value .. '","x":42}'

                local block = make_tool_call_block(
                    "json-stream",
                    "in_progress",
                    { placeholder }
                )
                writer:write_tool_call_block(block)

                writer:update_tool_call_block({
                    tool_call_id = "json-stream",
                    status = "completed",
                    body = { json_text },
                })

                local tracker = writer.tool_call_blocks["json-stream"]
                assert.is_not_nil(tracker)
                assert.equal(placeholder, tracker.body[1])

                local separator_idx
                for i, line in ipairs(tracker.body) do
                    if line == "---" then
                        separator_idx = i
                        break
                    end
                end
                assert.is_not_nil(separator_idx)
                assert.is_true(#tracker.body - separator_idx > 1)
            end
        )

        it("leaves malformed JSON unchanged", function()
            local malformed = "{" .. string.rep("not valid json ", 10) .. "}"

            local block =
                make_tool_call_block("json-bad", "completed", { malformed })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-bad"]
            assert.same({ malformed }, tracker.body)
        end)
    end)

    describe("tool call block update highlighting", function()
        it(
            "applies block body highlights synchronously during update",
            function()
                local block = make_tool_call_block("sync-hl-1", "pending")
                writer:write_tool_call_block(block)

                writer:update_tool_call_block({
                    tool_call_id = "sync-hl-1",
                    status = "completed",
                    body = { "new output" },
                })

                local ns =
                    vim.api.nvim_create_namespace("agentic_diff_highlights")
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    0,
                    -1,
                    { details = true }
                )

                local has_comment_hl = false
                for _, em in ipairs(extmarks) do
                    if em[4].hl_group == "Comment" then
                        has_comment_hl = true
                        break
                    end
                end
                assert.is_true(has_comment_hl)
            end
        )
    end)

    describe("Fold integration", function()
        local Fold = require("agentic.ui.tool_call_fold")
        --- @type agentic.UserConfig.Folding|nil
        local saved_folding

        before_each(function()
            saved_folding = Config.folding
        end)

        after_each(function()
            Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        end)

        --- Read the buffer rows for a block and return its layout slots.
        --- @param tool_call_id string
        --- @return integer start_row, integer top_pad_row, integer bottom_pad_row, integer end_row
        local function block_layout(tool_call_id)
            local tracker = writer.tool_call_blocks[tool_call_id]
            local NS = vim.api.nvim_create_namespace("agentic_tool_blocks")
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                NS,
                tracker.extmark_id,
                { details = true }
            )
            local start_row = pos[1]
            --- @type integer
            local end_row = pos[3].end_row
            return start_row, start_row + 1, end_row - 1, end_row
        end

        it(
            "closes a manual fold when update_tool_call_block crosses the fold threshold",
            function()
                Config.folding = {
                    tool_calls = { enabled = true, threshold = 5 },
                }
                Config.auto_scroll = { threshold = 10 }

                Fold.setup_window(winid, bufnr)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "intro" })
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:write_tool_call_block({
                    tool_call_id = "fold-mat",
                    status = "pending",
                    kind = "execute",
                    argument = "ls",
                    body = { "short" },
                })

                local _, top_pad_row = block_layout("fold-mat")
                vim.api.nvim_win_call(winid, function()
                    assert.equal(vim.fn.foldclosed(top_pad_row + 1), -1)
                end)

                writer:update_tool_call_block({
                    tool_call_id = "fold-mat",
                    status = "completed",
                    body = {
                        "L1",
                        "L2",
                        "L3",
                        "L4",
                        "L5",
                        "L6",
                        "L7",
                        "L8",
                        "L9",
                        "L10",
                    },
                })

                local _, new_top_pad_row, new_bottom_pad_row =
                    block_layout("fold-mat")
                vim.api.nvim_win_call(winid, function()
                    local fold_start = vim.fn.foldclosed(new_top_pad_row + 1)
                    local fold_end = vim.fn.foldclosedend(new_top_pad_row + 1)
                    assert.equal(fold_start, new_top_pad_row + 1)
                    assert.equal(fold_end, new_bottom_pad_row + 1)
                end)

                local tracker = writer.tool_call_blocks["fold-mat"]
                assert.is_true(tracker.has_fold == true)
            end
        )

        it(
            "closes a manual fold when write_tool_call_block crosses the fold threshold",
            function()
                Config.folding = {
                    tool_calls = { enabled = true, threshold = 5 },
                }
                Config.auto_scroll = { threshold = 10 }

                Fold.setup_window(winid, bufnr)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "intro" })
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:write_tool_call_block({
                    tool_call_id = "fold-on-write",
                    status = "completed",
                    kind = "execute",
                    argument = "ls",
                    body = {
                        "L1",
                        "L2",
                        "L3",
                        "L4",
                        "L5",
                        "L6",
                        "L7",
                        "L8",
                        "L9",
                        "L10",
                    },
                })

                local _, top_pad_row, bottom_pad_row =
                    block_layout("fold-on-write")
                vim.api.nvim_win_call(winid, function()
                    assert.equal(
                        vim.fn.foldclosed(top_pad_row + 1),
                        top_pad_row + 1
                    )
                    assert.equal(
                        vim.fn.foldclosedend(top_pad_row + 1),
                        bottom_pad_row + 1
                    )
                end)

                local tracker = writer.tool_call_blocks["fold-on-write"]
                assert.is_true(tracker.has_fold == true)
            end
        )

        it("does not create a fold when block stays below threshold", function()
            Config.folding = {
                tool_calls = { enabled = true, threshold = 5 },
            }
            Config.auto_scroll = { threshold = 10 }

            Fold.setup_window(winid, bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "intro" })
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })

            writer:write_tool_call_block({
                tool_call_id = "no-fold",
                status = "pending",
                kind = "execute",
                argument = "ls",
                body = { "L1", "L2", "L3" },
            })

            local tracker = writer.tool_call_blocks["no-fold"]
            assert.is_nil(tracker.has_fold)

            local _, top_pad_row = block_layout("no-fold")
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(top_pad_row + 1), -1)
            end)
        end)

        it("emits anchor pad lines around the body in every block", function()
            Config.folding = {
                tool_calls = { enabled = true, threshold = 5 },
            }
            Config.auto_scroll = { threshold = 10 }

            Fold.setup_window(winid, bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "intro" })

            writer:write_tool_call_block({
                tool_call_id = "anchors",
                status = "pending",
                kind = "execute",
                argument = "ls",
                body = { "B1", "B2" },
            })

            local start_row, top_pad_row, bottom_pad_row, end_row =
                block_layout("anchors")
            local lines =
                vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
            -- Layout: header, top_pad, B1, B2, bottom_pad, trailing
            assert.equal(#lines, 6)
            assert.equal(lines[2], "")
            assert.equal(lines[3], "B1")
            assert.equal(lines[4], "B2")
            assert.equal(lines[5], "")
            assert.equal(top_pad_row, start_row + 1)
            assert.equal(bottom_pad_row, end_row - 1)
        end)
    end)
end)
