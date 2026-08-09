--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, need-check-nil, undefined-field, param-type-mismatch, return-type-mismatch

local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ProviderSwitcher", function()
    local Config = require("agentic.config")
    local Logger = require("agentic.utils.logger")
    local SessionRegistry = require("agentic.session_registry")

    --- @type TestStub
    local current_stub
    --- @type TestStub
    local replace_stub
    --- @type TestStub
    local notify_stub
    --- @type agentic.SessionManager|nil
    local source
    --- @type agentic.SessionManager
    local target
    --- @type agentic.SessionReplacementOpts|nil
    local replacement_opts
    local original_provider
    --- @type integer[]
    local buffers

    --- @return integer bufnr
    local function create_buffer()
        local bufnr = vim.api.nvim_create_buf(false, true)
        buffers[#buffers + 1] = bufnr
        return bufnr
    end

    --- @return agentic.SessionManager source_session
    --- @return agentic.SessionManager target_session
    local function create_sessions()
        local source_input = create_buffer()
        local target_input = create_buffer()
        vim.api.nvim_buf_set_lines(
            source_input,
            0,
            -1,
            false,
            { "draft prompt", "second line" }
        )

        local source_messages = {
            {
                type = "user",
                text = "question",
                timestamp = 1,
                provider_name = "Claude",
                metadata = { nested = "source" },
            },
            {
                type = "tool_call",
                tool_call_id = "tool-1",
                status = "completed",
                body = { "result" },
                diff = { old = { "before" }, new = { "after" } },
                extmark_id = 41,
                has_fold = true,
                permission = {
                    sorted_options = {
                        { optionId = "allow_once", kind = "allow_once" },
                    },
                    is_focused = true,
                    focused_button_index = 1,
                },
                _rendered_button_count = 2,
                metadata = { nested = "tool" },
            },
        }
        local files = { "/tmp/one.lua", "/tmp/two.lua" }
        local selections = {
            {
                file_path = "one.lua",
                start_line = 1,
                end_line = 2,
                lines = { "one", "two" },
            },
        }
        local diagnostics = {
            {
                bufnr = source_input,
                lnum = 0,
                col = 0,
                message = "problem",
                file_path = "/tmp/one.lua",
                user_data = { nested = "diagnostic" },
            },
        }

        local source_session = {
            session_id = "source-session",
            is_generating = false,
            chat_history = {
                messages = source_messages,
                title = "Local title",
            },
            file_list = {
                get_files = function()
                    return vim.deepcopy(files)
                end,
            },
            code_selection = {
                get_selections = function()
                    return vim.deepcopy(selections)
                end,
            },
            diagnostics_list = {
                get_diagnostics = function()
                    return vim.deepcopy(diagnostics)
                end,
            },
            config_options = { owner = "source-options" },
            session_state = { owner = "source-state" },
            todo_list = { entries = { "source todo" } },
            message_writer = {
                tool_call_blocks = { ["tool-1"] = { owner = "source" } },
            },
            widget = {
                buf_nrs = {
                    input = source_input,
                    chat = create_buffer(),
                    todos = create_buffer(),
                },
            },
        }
        function source_session:owns_ready_acp_session(session_id)
            return self.session_id == session_id
        end

        local target_files = {}
        local target_selections = {}
        local target_diagnostics = {}
        local target_options = { owner = "target-options" }
        local target_state = { owner = "target-state" }
        local target_todos = { entries = { "target todo" } }
        local target_tool_blocks = { existing = { owner = "target" } }
        local target_session = {
            chat_history = { messages = {}, title = "" },
            history_to_send = nil,
            file_list = {
                _files = target_files,
                add = function(_, file_path)
                    target_files[#target_files + 1] = file_path
                end,
            },
            code_selection = {
                _selections = target_selections,
                add = function(_, selection)
                    target_selections[#target_selections + 1] = selection
                end,
            },
            diagnostics_list = {
                _diagnostics = target_diagnostics,
                add_many = function(_, items)
                    for _, item in ipairs(items) do
                        target_diagnostics[#target_diagnostics + 1] = item
                    end
                end,
            },
            config_options = target_options,
            session_state = target_state,
            todo_list = target_todos,
            message_writer = {
                tool_call_blocks = target_tool_blocks,
                replay_history_messages = function(self, messages)
                    self.replayed_messages = messages
                end,
            },
            widget = {
                buf_nrs = {
                    input = target_input,
                    chat = create_buffer(),
                    todos = create_buffer(),
                },
            },
        }
        function target_session:on_session_ready(_on_ready, on_failure)
            self._provider_switch_failure = on_failure
        end

        return source_session, --[[@as agentic.SessionManager]]
            target_session --[[@as agentic.SessionManager]]
    end

    local function switch_provider()
        package.loaded["agentic.provider_switcher"] = nil
        local ProviderSwitcher = require("agentic.provider_switcher")
        ProviderSwitcher.switch({ provider = "gemini-acp" })
    end

    before_each(function()
        buffers = {}
        original_provider = Config.provider
        Config.provider = "claude-agent-acp"
        source, target = create_sessions()
        replacement_opts = nil

        current_stub = spy.stub(SessionRegistry, "current")
        current_stub:invokes(function()
            return source
        end)
        replace_stub = spy.stub(SessionRegistry, "replace")
        replace_stub:invokes(
            function(_source, _provider_name, _start_spec, opts)
                replacement_opts = opts
                return target
            end
        )
        notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        Config.provider = original_provider
        current_stub:revert()
        replace_stub:revert()
        notify_stub:revert()
        package.loaded["agentic.provider_switcher"] = nil

        for _, bufnr in ipairs(buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end
    end)

    it(
        "delegates one new-session replacement to the selected provider",
        function()
            switch_provider()

            assert.spy(replace_stub).was.called(1)
            local call = replace_stub.calls[1]
            assert.equal(source, call[1])
            assert.equal("gemini-acp", call[2])
            assert.same({ kind = "new" }, call[3])
        end
    )

    it(
        "keeps the source and provider unchanged when target startup fails",
        function()
            switch_provider()

            assert.equal("claude-agent-acp", Config.provider)
            assert.equal("source-session", source.session_id)
            assert.is_not_nil(target._provider_switch_failure)

            target._provider_switch_failure(target)

            assert.equal("claude-agent-acp", Config.provider)
            assert.equal("source-session", source.session_id)
            assert.spy(notify_stub).was.called(1)
        end
    )

    it("commits the provider only after replacement placement", function()
        switch_provider()
        assert.is_not_nil(replacement_opts)

        replacement_opts.prepare(source, target)
        assert.equal("claude-agent-acp", Config.provider)

        replacement_opts.on_commit(target, source)
        assert.equal("gemini-acp", Config.provider)
    end)

    it("copies allowed continuity into independent containers", function()
        switch_provider()
        replacement_opts.prepare(source, target)

        assert.equal(
            #source.chat_history.messages,
            #target.chat_history.messages
        )
        assert.same(
            source.chat_history.messages[1],
            target.chat_history.messages[1]
        )
        assert.is_false(
            rawequal(source.chat_history.messages, target.chat_history.messages)
        )
        assert.is_false(
            rawequal(
                source.chat_history.messages[1].metadata,
                target.chat_history.messages[1].metadata
            )
        )
        assert.equal("Local title", target.chat_history.title)
        assert.same({ "/tmp/one.lua", "/tmp/two.lua" }, target.file_list._files)
        assert.same(
            { "one", "two" },
            target.code_selection._selections[1].lines
        )
        assert.is_false(
            rawequal(
                source.code_selection:get_selections()[1].lines,
                target.code_selection._selections[1].lines
            )
        )
        assert.equal(
            "diagnostic",
            target.diagnostics_list._diagnostics[1].user_data.nested
        )
        local stored_tool_call = target.chat_history.messages[2]
        assert.same({ "result" }, stored_tool_call.body)
        assert.same(
            { old = { "before" }, new = { "after" } },
            stored_tool_call.diff
        )
        assert.is_nil(stored_tool_call.extmark_id)
        assert.is_nil(stored_tool_call.has_fold)
        assert.is_nil(stored_tool_call.permission)
        assert.is_nil(stored_tool_call._rendered_button_count)

        local target_input = vim.api.nvim_buf_get_lines(
            target.widget.buf_nrs.input,
            0,
            -1,
            false
        )
        assert.same({ "draft prompt", "second line" }, target_input)
    end)

    it("does not transfer prior-provider or manager-owned state", function()
        local target_options = target.config_options
        local target_state = target.session_state
        local target_todos = target.todo_list
        local target_tool_blocks = target.message_writer.tool_call_blocks
        local target_chat_bufnr = target.widget.buf_nrs.chat

        switch_provider()
        replacement_opts.prepare(source, target)

        assert.equal(target_options, target.config_options)
        assert.equal(target_state, target.session_state)
        assert.equal(target_todos, target.todo_list)
        assert.equal(target_tool_blocks, target.message_writer.tool_call_blocks)
        assert.same({ "target todo" }, target.todo_list.entries)
        assert.same(
            { existing = { owner = "target" } },
            target.message_writer.tool_call_blocks
        )
        assert.equal(target_chat_bufnr, target.widget.buf_nrs.chat)
        assert.are_not.equal(
            source.widget.buf_nrs.chat,
            target.widget.buf_nrs.chat
        )
    end)

    it("separates stored, prompt, and rendered transcript copies", function()
        switch_provider()
        replacement_opts.prepare(source, target)

        local stored = target.chat_history.messages
        local prompt = target.history_to_send
        local rendered = target.message_writer.replayed_messages

        assert.is_false(rawequal(stored, prompt))
        assert.is_false(rawequal(stored, rendered))
        assert.is_false(rawequal(prompt, rendered))
        assert.is_false(rawequal(stored[1].metadata, prompt[1].metadata))
        assert.is_false(rawequal(stored[1].metadata, rendered[1].metadata))
        assert.is_nil(prompt[2].extmark_id)
        assert.is_nil(prompt[2].permission)
        assert.is_nil(rendered[2].has_fold)
        assert.is_nil(rendered[2]._rendered_button_count)
        assert.same(stored, prompt)
        assert.same(stored, rendered)
    end)

    it("uses no continuity prepare callback without a source", function()
        source = nil

        switch_provider()

        assert.spy(replace_stub).was.called(1)
        assert.is_nil(replace_stub.calls[1][1])
        assert.is_nil(replacement_opts.prepare)
        assert.same({}, target.chat_history.messages)
        assert.same({}, target.file_list._files)
        assert.same({}, target.code_selection._selections)
        assert.same({}, target.diagnostics_list._diagnostics)
    end)
end)
