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

    local function noop_callbacks()
        return {
            set_mode = function() end,
            set_model = function() end,
            set_thought_level = function() end,
        }
    end

    local function format_all(items, opts)
        return vim.tbl_map(function(item)
            return opts.format_item(item)
        end, items)
    end

    --- Build a model ConfigOption with the given currentValue.
    local function make_model_option(current_value)
        ---@diagnostic disable-next-line: missing-fields
        local option = {
            id = "model-1",
            category = "model",
            currentValue = current_value,
            name = "Model",
            options = {
                ---@diagnostic disable-next-line: missing-fields
                { value = "m1", name = "M1" },
                ---@diagnostic disable-next-line: missing-fields
                { value = "m2", name = "M2" },
            },
        }
        return option --[[@as agentic.acp.ConfigOption]]
    end

    local function make_legacy_models(current_model_id)
        return {
            availableModels = {
                { modelId = "m1", name = "M1", description = "D1" },
                { modelId = "m2", name = "M2", description = "D2" },
            },
            currentModelId = current_model_id,
        }
    end

    --- Build a fake session that wires the real SessionManager handlers
    --- onto a plain table with the given agent.
    local function make_session(agent)
        ---@type any
        local session = {
            session_id = "s1",
            config_options = AgentConfigOptions:new({}, noop_callbacks()),
            agent = agent,
            ---@diagnostic disable-next-line: invisible
            _handle_model_change = SessionManager._handle_model_change,
            ---@diagnostic disable-next-line: invisible
            _handle_thought_level_change = SessionManager._handle_thought_level_change,
            ---@diagnostic disable-next-line: invisible
            _handle_new_config_options = SessionManager._handle_new_config_options,
        }
        return session
    end

    --- Capture the items rendered by the next vim.ui.select call.
    --- Returns the table that will be populated when the selector runs.
    local function capture_render(on_choice_index)
        local rendered = {}
        select_stub:invokes(function(items, opts, on_choice)
            for i, line in ipairs(format_all(items, opts)) do
                rendered[i] = line
            end
            on_choice(on_choice_index and items[on_choice_index] or nil)
        end)
        return rendered
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
            local config = AgentConfigOptions:new({}, noop_callbacks())
            ---@diagnostic disable-next-line: missing-fields
            config:set_options({ make_model_option("m2") })

            local handle_model_change = function(model_id)
                ---@diagnostic disable-next-line: missing-fields
                config:set_options({ make_model_option(model_id) })
            end

            -- Initial render: m2 is current, select m1 (items[2] after reorder)
            local first_render = capture_render(2)
            config:show_model_selector(handle_model_change)
            assert.same({ "● M2", "  M1" }, first_render)

            -- Re-open: m1 is now current
            local second_render = capture_render(nil)
            config:show_model_selector(handle_model_change)
            assert.same({ "● M1", "  M2" }, second_render)
        end)
    end)

    describe("AgentModels (legacy provider integration)", function()
        it("marks initial legacy model and updates after success", function()
            local session = make_session({
                set_model = function(_self, _id, _model, callback)
                    callback({}, nil)
                end,
            })
            session.config_options:set_legacy_models(make_legacy_models("m2"))

            local first_render = capture_render(nil)
            session.config_options:show_model_selector(function() end)
            assert.same({ "● M2: D2", "  M1: D1" }, first_render)

            ---@diagnostic disable-next-line: invisible
            session:_handle_model_change("m1", true)

            assert.equal(
                "m1",
                session.config_options.legacy_agent_models.current_model_id
            )

            local second_render = capture_render(nil)
            session.config_options:show_model_selector(
                function(model_id, is_legacy)
                    ---@diagnostic disable-next-line: invisible
                    session:_handle_model_change(model_id, is_legacy)
                end
            )
            assert.same({ "● M1: D1", "  M2: D2" }, second_render)
        end)

        --- Run a legacy model change and return the on_done spy.
        local function run_model_change(set_model_fn)
            local session = make_session({
                set_model = set_model_fn,
                set_config_option = function(_self, _sid, _cid, _val, cb)
                    cb({ configOptions = {} }, nil)
                end,
            })
            session.config_options:set_legacy_models({
                availableModels = {
                    { modelId = "m1", name = "M1", description = "D1" },
                },
                currentModelId = "m1",
            })

            local on_done_spy = spy.new(function() end)
            ---@diagnostic disable-next-line: invisible
            session:_handle_model_change(
                "m1",
                true,
                on_done_spy --[[@as function]]
            )
            return on_done_spy
        end

        it("invokes on_done after successful model change", function()
            local on_done_spy = run_model_change(
                function(_self, _sid, _model, callback)
                    callback({}, nil)
                end
            )
            assert.equal(1, on_done_spy.call_count)
        end)

        it("does NOT invoke on_done when model change errors", function()
            local on_done_spy = run_model_change(
                function(_self, _sid, _model, callback)
                    callback(nil, { message = "boom" })
                end
            )
            assert.equal(0, on_done_spy.call_count)
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
            session = make_session({
                set_config_option = function() end,
            })
            session.session_id = "sess-1"
            set_config_stub = spy.stub(session.agent, "set_config_option")
            notify_stub:reset()
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

        it("does nothing when no thought_level option is set", function()
            session:_handle_thought_level_change("max")

            assert.equal(0, set_config_stub.call_count)
        end)

        it("sends configId from stored option id (Claude id)", function()
            session.config_options:set_options({
                make_thought_option("claude-effort-cfg", "effort"),
            })

            session:_handle_thought_level_change("max")

            assert.equal(1, set_config_stub.call_count)
            -- call[1]=self, [2]=session_id, [3]=configId, [4]=value, [5]=cb
            local call = set_config_stub.calls[1]
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

            -- Stale callback dropped: thought_level option NOT replaced
            assert.equal(
                "claude-effort-cfg",
                session.config_options.thought_level.id
            )
        end)
    end)
end)
