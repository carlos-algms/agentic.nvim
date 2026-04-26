local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentConfigOptions = require("agentic.acp.agent_config_options")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

describe("config selector", function()
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local select_stub

    local format_all = function(items, opts)
        return vim.tbl_map(function(item)
            return opts.format_item(item)
        end, items)
    end

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
        select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        notify_stub:revert()
        select_stub:revert()
    end)

    describe("AgentConfigOptions (modern provider)", function()
        it("marks default model and updates after selection", function()
            local config = AgentConfigOptions:new({}, {
                set_mode = function() end,
                set_model = function() end,
                set_thought_level = function() end,
            })
            ---@diagnostic disable-next-line: missing-fields
            config:set_options({
                ---@diagnostic disable-next-line: missing-fields
                {
                    id = "model-1",
                    category = "model",
                    currentValue = "m2",
                    name = "Model",
                    options = {
                        ---@diagnostic disable-next-line: missing-fields
                        { value = "m1", name = "M1" },
                        ---@diagnostic disable-next-line: missing-fields
                        { value = "m2", name = "M2" },
                    },
                },
            })

            -- Simulate provider update after selection
            local handle_model_change = function(model_id)
                ---@diagnostic disable-next-line: missing-fields
                config:set_options({
                    ---@diagnostic disable-next-line: missing-fields
                    {
                        id = "model-1",
                        category = "model",
                        currentValue = model_id,
                        name = "Model",
                        options = {
                            ---@diagnostic disable-next-line: missing-fields
                            { value = "m1", name = "M1" },
                            ---@diagnostic disable-next-line: missing-fields
                            { value = "m2", name = "M2" },
                        },
                    },
                })
            end

            -- Verify initial state and select m1
            local first_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                first_render = format_all(items, opts)
                on_choice(items[2]) -- select m1
            end)
            config:show_model_selector(handle_model_change)

            assert.same({ "● M2", "  M1" }, first_render)

            -- Re-open to verify it was updated
            local second_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                second_render = format_all(items, opts)
                on_choice(nil)
            end)
            config:show_model_selector(handle_model_change)

            assert.same({ "● M1", "  M2" }, second_render)
        end)
    end)

    describe("AgentModels (legacy provider integration)", function()
        it("marks initial legacy model and updates after success", function()
            -- Setup minimal session that uses the REAL _handle_model_change logic
            ---@type any
            local session = {
                session_id = "s1",
                config_options = AgentConfigOptions:new({}, {
                    set_mode = function() end,
                    set_model = function() end,
                    set_thought_level = function() end,
                }),
                agent = {
                    set_model = function(_self, _id, _model, callback)
                        callback({}, nil) -- Success
                    end,
                },
                ---@diagnostic disable-next-line: invisible
                _handle_model_change = SessionManager._handle_model_change,
            }

            session.config_options:set_legacy_models({
                availableModels = {
                    { modelId = "m1", name = "M1", description = "D1" },
                    { modelId = "m2", name = "M2", description = "D2" },
                },
                currentModelId = "m2",
            })

            -- Verify initial state
            local first_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                first_render = format_all(items, opts)
                on_choice(nil)
            end)
            session.config_options:show_model_selector(function() end)

            assert.same({ "● M2: D2", "  M1: D1" }, first_render)

            -- Call the REAL _handle_model_change
            ---@diagnostic disable-next-line: invisible
            session:_handle_model_change("m1", true)

            -- Verify the fix: legacy_agent_models state should be updated via SessionManager callback
            assert.equal(
                "m1",
                session.config_options.legacy_agent_models.current_model_id
            )

            -- Verify UI also reflects it when re-opening
            local second_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                second_render = format_all(items, opts)
                on_choice(nil)
            end)

            -- Selection logic triggers model change handler
            session.config_options:show_model_selector(
                function(model_id, is_legacy)
                    ---@diagnostic disable-next-line: invisible
                    session:_handle_model_change(model_id, is_legacy)
                end
            )

            assert.same({ "● M1: D1", "  M2: D2" }, second_render)
        end)
    end)

    describe("_handle_thought_level_change", function()
        --- @type any
        local session
        --- @type TestStub
        local set_config_stub

        --- Build a multi-option ConfigOption with a custom id, so tests
        --- that assert configId came from `option.id` (not `option.category`)
        --- actually prove that — the id and category must differ.
        local function make_thought_option(id, category)
            ---@diagnostic disable-next-line: missing-fields
            return {
                id = id,
                category = category,
                currentValue = "low",
                description = "",
                name = "Effort",
                options = {
                    ---@diagnostic disable-next-line: missing-fields
                    { value = "low", name = "Low" },
                    ---@diagnostic disable-next-line: missing-fields
                    { value = "high", name = "High" },
                    ---@diagnostic disable-next-line: missing-fields
                    { value = "max", name = "Max" },
                },
            }
        end

        before_each(function()
            session = {
                session_id = "sess-1",
                config_options = AgentConfigOptions:new({}, {
                    set_mode = function() end,
                    set_model = function() end,
                    set_thought_level = function() end,
                }),
                agent = {
                    set_config_option = function(
                        _self,
                        _sid,
                        _cid,
                        _value,
                        _cb
                    )
                    end,
                },
                ---@diagnostic disable-next-line: invisible
                _handle_thought_level_change = SessionManager._handle_thought_level_change,
                ---@diagnostic disable-next-line: invisible
                _handle_new_config_options = SessionManager._handle_new_config_options,
            }
            set_config_stub = spy.stub(session.agent, "set_config_option")
        end)

        after_each(function()
            set_config_stub:revert()
        end)

        it("does nothing when session_id is nil", function()
            session.session_id = nil
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })

            session:_handle_thought_level_change("max")

            assert.equal(0, set_config_stub.call_count)
        end)

        it("sends configId from stored option id (Claude id)", function()
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })

            session:_handle_thought_level_change("max")

            assert.equal(1, set_config_stub.call_count)
            local call = set_config_stub.calls[1]
            -- call[1] is self (agent), call[2] is session_id,
            -- call[3] is configId, call[4] is value, call[5] is callback
            assert.equal("sess-1", call[2])
            assert.equal("claude-effort-cfg", call[3])
            assert.equal("max", call[4])
            assert.equal("function", type(call[5]))
        end)

        it("uses Codex id when provider sends thought_level", function()
            session.config_options:set_options({
                make_thought_option("codex-thought-cfg", "thought_level"),
            })

            session:_handle_thought_level_change("high")

            local call = set_config_stub.calls[1]
            assert.equal("codex-thought-cfg", call[3])
            assert.equal("high", call[4])
        end)

        it("applies new configOptions on success", function()
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })
            set_config_stub:invokes(function(_self, _sid, _cid, _value, cb)
                cb({
                    configOptions = {
                        make_thought_option("claude-effort-cfg", "effort"),
                    },
                }, nil)
            end)

            session:_handle_thought_level_change("max")

            assert.is_not_nil(session.config_options.thought_level)
            assert.equal(
                "claude-effort-cfg",
                session.config_options.thought_level.id
            )
        end)

        it("notifies error when agent returns error", function()
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })
            set_config_stub:invokes(function(_self, _sid, _cid, _value, cb)
                cb(nil, { message = "boom" })
            end)
            notify_stub:reset()

            session:_handle_thought_level_change("max")

            assert.equal(1, notify_stub.call_count)
            local call = notify_stub.calls[1]
            assert.is_true(call[1]:find("boom") ~= nil)
            assert.equal(vim.log.levels.ERROR, call[2])
        end)

        it("drops stale callback when session_id changes mid-flight", function()
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })
            local captured_cb
            set_config_stub:invokes(function(_self, _sid, _cid, _value, cb)
                captured_cb = cb
            end)

            session:_handle_thought_level_change("max")
            session.session_id = "sess-2"
            captured_cb({
                configOptions = {
                    make_thought_option("renamed-id", "effort"),
                },
            }, nil)

            -- thought_level option should NOT have been replaced — the
            -- stale callback dropped before applying the new options
            assert.equal(
                "claude-effort-cfg",
                session.config_options.thought_level.id
            )
        end)
    end)
end)
