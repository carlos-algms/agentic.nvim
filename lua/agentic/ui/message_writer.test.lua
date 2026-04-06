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

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_message_update(text)
        return {
            sessionUpdate = "agent_message_chunk",
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

    describe("_auto_scroll", function()
        it("evaluates _check_auto_scroll eagerly on first call", function()
            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)

        it("coalesces multiple calls into a single scheduled scroll", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it(
            "remains true after buffer growth despite cursor exceeding threshold",
            function()
                setup_buffer(20, 20)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                local lines = {}
                for i = 1, 30 do
                    lines[i] = "tool output " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

                local check_spy = spy.on(writer, "_check_auto_scroll")
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)
                assert.equal(0, check_spy.call_count)
                check_spy:revert()
            end
        )

        it(
            "scheduled callback resets field and moves cursor to last line",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 1)
                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.is_nil(writer._should_auto_scroll)
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                schedule_stub:revert()
            end
        )

        it(
            "scheduled callback scrolls when user is on a different tabpage",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(20, 20)

                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

                schedule_stub:revert()
            end
        )

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_nil(writer._should_auto_scroll)
                assert.is_false(writer._scroll_scheduled)

                schedule_stub:revert()

                schedule_stub = spy.stub(vim, "schedule")

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write_message captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                writer:write_message(
                    make_message_update(table.concat(long_text, "\n"))
                )

                assert.is_true(writer._should_auto_scroll)
            end
        )

        it(
            "write_tool_call_block captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local body = {}
                for i = 1, 15 do
                    body[i] = "file" .. i .. ".lua"
                end

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = body,
                }
                writer:write_tool_call_block(block)

                assert.is_true(writer._should_auto_scroll)
                assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
            end
        )

        it("write_message does not scroll when user has scrolled up", function()
            setup_buffer(50, 1)

            writer:write_message(
                make_message_update("new content\nmore content")
            )

            assert.is_false(writer._should_auto_scroll)
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

                writer:write_message(make_message_update("hello"))
                writer:write_message_chunk(make_message_update("chunk"))
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

            writer:write_message(make_message_update(""))
            writer:write_message_chunk(make_message_update(""))

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

        --- @return string[]
        local function get_all_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
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

        it("writes user header on first user_message_chunk", function()
            writer:write_message_chunk(
                make_update("hello", "user_message_chunk")
            )

            local lines = get_all_lines()
            local header_found = false
            for _, line in ipairs(lines) do
                if line:match("^## .* User %- %d%d%d%d%-%d%d%-%d%d") then
                    header_found = true
                    break
                end
            end
            assert.is_true(header_found)
        end)

        it("writes agent header on first agent_message_chunk", function()
            writer:set_provider_name("TestAgent")
            writer:write_message_chunk(
                make_update("response", "agent_message_chunk")
            )

            local lines = get_all_lines()
            local header_found = false
            for _, line in ipairs(lines) do
                if line:match("### .* Agent %- TestAgent") then
                    header_found = true
                    break
                end
            end
            assert.is_true(header_found)
        end)

        it("skips header for consecutive same sender", function()
            writer:write_message_chunk(
                make_update("msg1", "user_message_chunk")
            )
            writer:write_message_chunk(
                make_update("msg2", "user_message_chunk")
            )

            local lines = get_all_lines()
            local header_count = 0
            for _, line in ipairs(lines) do
                if line:match("^## .* User") then
                    header_count = header_count + 1
                end
            end
            assert.equal(1, header_count)
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

            local lines = get_all_lines()
            local header_found = false
            local has_timestamp = false
            for _, line in ipairs(lines) do
                if line:match("^## .* User$") then
                    header_found = true
                end
                if line:match("^## .* User %- %d%d%d%d") then
                    has_timestamp = true
                end
            end
            assert.is_true(header_found)
            assert.is_false(has_timestamp)
        end)

        it("skips header for plan updates", function()
            writer:_maybe_write_sender_header("plan")

            local lines = get_all_lines()
            local has_header = false
            for _, line in ipairs(lines) do
                if line:match("Agent") or line:match("User") then
                    has_header = true
                end
            end
            assert.is_false(has_header)
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

                local lines = get_all_lines()
                local agent_header_found = false
                for _, line in ipairs(lines) do
                    if line:match("### .* Agent %- TestAgent") then
                        agent_header_found = true
                        break
                    end
                end
                assert.is_true(agent_header_found)
            end
        )
    end)

    describe("replay_history_messages", function()
        local function get_all_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("replays user and agent messages with headers", function()
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
                    text = "hi there",
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            local lines = get_all_lines()
            local content = table.concat(lines, "\n")

            -- Verify user header and message
            assert.truthy(content:match("## .* User"))
            assert.truthy(content:match("hello"))

            -- Verify agent header and message
            assert.truthy(content:match("### .* Agent %- Claude"))
            assert.truthy(content:match("hi there"))
        end)

        it("shows correct provider name per message", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "user",
                    text = "question from user",
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

            local lines = get_all_lines()
            local content = table.concat(lines, "\n")

            -- Both provider headers should appear with correct names
            assert.truthy(content:match("### .* Agent %- Claude"))
            assert.truthy(content:match("### .* Agent %- Gemini"))
            assert.truthy(content:match("from claude"))
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

            -- After replay, provider should be restored
            assert.equal("Claude", writer._provider_name)
        end)

        it("handles thought chunk messages", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "thought",
                    text = "thinking about this",
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            local lines = get_all_lines()
            local content = table.concat(lines, "\n")

            assert.truthy(content:match("thinking about this"))
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

            -- Tool call should be tracked
            assert.is_not_nil(writer.tool_call_blocks["tc-1"])

            -- Tool call content should be rendered in buffer
            local lines = get_all_lines()
            local content = table.concat(lines, "\n")
            assert.truthy(content:match("read"))
        end)
    end)

    describe("thinking block highlighting", function()
        --- @param text string
        --- @return agentic.acp.SessionUpdateMessage
        local function make_thought_update(text)
            return {
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = text },
            }
        end

        it("clears thinking state on reset_sender_tracking", function()
            writer:write_message_chunk(make_thought_update("thinking..."))
            assert.is_not_nil(writer._thinking_extmark_id)

            writer:reset_sender_tracking()
            assert.is_nil(writer._thinking_extmark_id)
            assert.is_nil(writer._thinking_start_line)
            assert.is_nil(writer._thinking_end_line)
        end)

        it("creates extmark on first thought chunk", function()
            writer:write_message_chunk(make_thought_update("hello"))

            assert.is_not_nil(writer._thinking_extmark_id)
            assert.is_not_nil(writer._thinking_start_line)

            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_create_namespace("agentic_thinking"),
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            assert.equal("AgenticThinking", details.hl_group)
            assert.is_true(details.hl_eol)
        end)

        it("prepends brain emoji on first thought chunk", function()
            writer:write_message_chunk(make_thought_update("thinking"))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local found = false
            for _, line in ipairs(lines) do
                if line:find("🧠 thinking") then
                    found = true
                    break
                end
            end

            assert.is_true(found)
        end)

        it("does not prepend emoji on subsequent thought chunks", function()
            writer:write_message_chunk(make_thought_update("first"))
            writer:write_message_chunk(make_thought_update(" second"))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local emoji_count = 0
            for _, line in ipairs(lines) do
                if line:find("🧠") then
                    emoji_count = emoji_count + 1
                end
            end

            assert.equal(1, emoji_count)
        end)

        it("updates extmark end_row when thought adds newlines", function()
            writer:write_message_chunk(make_thought_update("line1"))
            local initial_end = writer._thinking_end_line

            writer:write_message_chunk(make_thought_update("\nline2"))

            assert.is_true(writer._thinking_end_line > initial_end)

            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_create_namespace("agentic_thinking"),
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #extmarks)
            assert.equal(writer._thinking_end_line, extmarks[1][4].end_row)
        end)

        it("highlights thought messages during history replay", function()
            writer:replay_history_messages({
                {
                    type = "agent",
                    text = "hello",
                },
                {
                    type = "thought",
                    text = "let me think\nabout this",
                },
                {
                    type = "agent",
                    text = "done",
                },
            })

            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_create_namespace("agentic_thinking"),
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            assert.equal("AgenticThinking", details.hl_group)
            assert.is_true(details.hl_eol)
        end)

        it("prepends brain emoji in replayed thought messages", function()
            writer:replay_history_messages({
                {
                    type = "thought",
                    text = "pondering",
                },
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local found = false
            for _, line in ipairs(lines) do
                if line:find("🧠 pondering") then
                    found = true
                    break
                end
            end

            assert.is_true(found)
        end)

        it("stops updating extmark when switching to message", function()
            writer:write_message_chunk(make_thought_update("thinking"))
            local extmark_id = writer._thinking_extmark_id
            assert.is_not_nil(extmark_id)

            writer:write_message_chunk(make_message_update("response"))

            assert.is_nil(writer._thinking_extmark_id)

            -- Extmark still exists in buffer (not deleted)
            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_create_namespace("agentic_thinking"),
                0,
                -1,
                {}
            )
            assert.equal(1, #extmarks)
        end)

        it("sets end_col to cover the full text on the last line", function()
            writer:write_message_chunk(
                make_thought_update("single line thought")
            )

            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            -- end_col must cover the text, not be 0
            assert.is_true(details.end_col > 0)

            local end_row = details.end_row
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                end_row,
                end_row + 1,
                false
            )[1]
            assert.equal(#line, details.end_col)
        end)

        it("updates extmark end_col when text appends to same line", function()
            writer:write_message_chunk(make_thought_update("start"))

            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local before = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            local end_col_before = before[1][4].end_col

            -- Append to same line (no leading newline)
            writer:write_message_chunk(make_thought_update(" more text"))

            local after = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            local end_col_after = after[1][4].end_col

            assert.is_true(end_col_after > end_col_before)
        end)

        it(
            "starts extmark at thought content line, not blank separator after header",
            function()
                -- User message sets _last_sender = "user"
                writer:write_message_chunk({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "question" },
                })

                -- Thought triggers agent header (sender change)
                writer:write_message_chunk(make_thought_update("deep thinking"))

                local ns = vim.api.nvim_create_namespace("agentic_thinking")
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    0,
                    -1,
                    { details = true }
                )

                assert.equal(1, #extmarks)
                local start_row = extmarks[1][2]

                -- Start line must contain actual thought text, not be blank
                local start_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    start_row,
                    start_row + 1,
                    false
                )[1]
                assert.truthy(start_line_text:find("🧠"))
            end
        )

        it("clears thinking state when tool call block is written", function()
            writer:write_message_chunk(make_thought_update("thinking..."))
            assert.is_not_nil(writer._thinking_extmark_id)

            writer:write_tool_call_block(
                make_tool_call_block("tc-clear-1", "pending")
            )

            assert.is_nil(writer._thinking_extmark_id)
            assert.is_nil(writer._thinking_start_line)
            assert.is_nil(writer._thinking_end_line)
        end)

        it("clears thinking state when write_message is called", function()
            writer:write_message_chunk(make_thought_update("thinking..."))
            assert.is_not_nil(writer._thinking_extmark_id)

            writer:write_message({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "full response" },
            })

            assert.is_nil(writer._thinking_extmark_id)
            assert.is_nil(writer._thinking_start_line)
            assert.is_nil(writer._thinking_end_line)
        end)

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

            -- Both extmarks should exist in the buffer
            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
            assert.equal(2, #extmarks)
        end)

        it("replay thought extmark has end_col covering full text", function()
            writer:replay_history_messages({
                {
                    type = "thought",
                    text = "thinking about this",
                },
            })

            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            assert.is_true(details.end_col > 0)

            local end_row = details.end_row
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                end_row,
                end_row + 1,
                false
            )[1]
            assert.equal(#line, details.end_col)
        end)

        it(
            "replay thought extmark covers content lines, not trailing blank",
            function()
                writer:replay_history_messages({
                    {
                        type = "thought",
                        text = "line one\nline two",
                    },
                })

                local ns = vim.api.nvim_create_namespace("agentic_thinking")
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    0,
                    -1,
                    { details = true }
                )

                assert.equal(1, #extmarks)
                local details = extmarks[1][4] --- @type table
                local start_row = extmarks[1][2]
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
            end
        )
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

                -- Highlights must be present immediately after update
                -- (not deferred via vim.schedule)
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
end)
