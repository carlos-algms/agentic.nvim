local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentConfigOptions", function()
    --- @type agentic.acp.AgentConfigOptions
    local AgentConfigOptions

    --- @type agentic.acp.AgentConfigOptions
    local config_options

    --- @type TestStub
    local multi_keymap_stub

    --- @type agentic.acp.ConfigOption
    local mode_option = {
        id = "mode-1",
        category = "mode",
        currentValue = "normal",
        description = "Agent mode",
        name = "Mode",
        options = {
            {
                value = "normal",
                name = "Normal",
                description = "Standard mode",
            },
            { value = "plan", name = "Plan", description = "Planning mode" },
            { value = "code", name = "Code", description = "Coding mode" },
        },
    }

    --- @type agentic.acp.ConfigOption
    local model_option = {
        id = "model-1",
        category = "model",
        currentValue = "claude-sonnet",
        description = "Model selection",
        name = "Model",
        options = {
            {
                value = "claude-sonnet",
                name = "Sonnet",
                description = "Fast model",
            },
            {
                value = "claude-opus",
                name = "Opus",
                description = "Powerful model",
            },
        },
    }

    --- @type agentic.acp.ConfigOption
    local thought_option = {
        id = "thought-1",
        category = "thought_level",
        currentValue = "normal",
        description = "Thinking depth",
        name = "Thought Level",
        options = {
            { value = "normal", name = "Normal", description = "Standard" },
        },
    }

    --- @type agentic.acp.ConfigOption
    local multi_thought = {
        id = "thought-multi",
        category = "thought_level",
        currentValue = "low",
        description = "",
        name = "Thought Level",
        options = {
            { value = "low", name = "Low", description = "" },
            { value = "high", name = "High", description = "" },
            { value = "max", name = "Max", description = "" },
        },
    }

    --- @type integer
    local test_bufnr

    --- @return agentic.acp.AgentConfigOptions
    local function make_fresh()
        return AgentConfigOptions:new({ chat = test_bufnr }, {
            set_mode = function() end,
            set_model = function() end,
            set_thought_level = function() end,
        })
    end

    before_each(function()
        local BufHelpers = require("agentic.utils.buf_helpers")
        multi_keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

        AgentConfigOptions = require("agentic.acp.agent_config_options")
        test_bufnr = vim.api.nvim_create_buf(false, true)
        config_options = make_fresh()
    end)

    after_each(function()
        multi_keymap_stub:revert()
        vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end)

    describe("constructor", function()
        it(
            "registers 3 keymaps per buffer (mode, model, thought_level)",
            function()
                assert.stub(multi_keymap_stub).was.called(3)

                for i = 1, 3 do
                    assert.equal(
                        "function",
                        type(multi_keymap_stub.calls[i][3])
                    )
                end
            end
        )
    end)

    describe("set_options", function()
        it("assigns all known categories from a single call", function()
            config_options:set_options({
                mode_option,
                model_option,
                thought_option,
            })

            assert.equal("mode-1", config_options.mode.id)
            assert.equal("model-1", config_options.model.id)
            assert.equal("thought-1", config_options.thought_level.id)
        end)

        it("does nothing when configOptions is nil", function()
            config_options:set_options(nil)

            assert.is_nil(config_options.mode)
            assert.is_nil(config_options.model)
            assert.is_nil(config_options.thought_level)
        end)

        it("treats category 'effort' as alias for 'thought_level'", function()
            --- @type agentic.acp.ConfigOption
            local effort_option = vim.tbl_extend("force", mode_option, {
                id = "effort",
                category = "effort",
                currentValue = "high",
                name = "Effort",
                description = "Available effort levels for this model",
                options = {
                    { value = "low", name = "Low", description = "" },
                    { value = "medium", name = "Medium", description = "" },
                    { value = "high", name = "High", description = "" },
                    { value = "xhigh", name = "Xhigh", description = "" },
                    { value = "max", name = "Max", description = "" },
                },
            }) --[[@as agentic.acp.ConfigOption]]

            config_options:set_options({ effort_option })

            assert.is_not_nil(config_options.thought_level)
            assert.equal("effort", config_options.thought_level.id)
            assert.equal("high", config_options.thought_level.currentValue)
            assert.equal(
                #effort_option.options,
                #config_options.thought_level.options
            )
        end)

        describe("with Logger.debug stubbed", function()
            --- @type TestStub
            local debug_stub

            before_each(function()
                local Logger = require("agentic.utils.logger")
                debug_stub = spy.stub(Logger, "debug")
            end)

            after_each(function()
                debug_stub:revert()
            end)

            it("silently drops categories starting with '_'", function()
                local custom = vim.tbl_extend("force", mode_option, {
                    category = "_my_custom_thing",
                }) --[[@as agentic.acp.ConfigOption]]

                config_options:set_options({ custom })

                assert.equal(0, debug_stub.call_count)
                assert.is_nil(config_options.mode)
                assert.is_nil(config_options.model)
                assert.is_nil(config_options.thought_level)
            end)

            it("logs debug for unknown non-underscore categories", function()
                local unknown = vim.tbl_extend("force", mode_option, {
                    category = "totally_made_up",
                }) --[[@as agentic.acp.ConfigOption]]

                config_options:set_options({ unknown })

                assert.equal(1, debug_stub.call_count)
                assert.is_nil(config_options.mode)
                assert.is_nil(config_options.model)
                assert.is_nil(config_options.thought_level)
            end)
        end)
    end)

    --- get_mode / get_model / get_thought_level all delegate to the same
    --- private `getter`. One parameterized describe covers all three.
    for _, case in ipairs({
        {
            method = "get_mode",
            option = mode_option,
            present = "plan",
            present_name = "Plan",
        },
        {
            method = "get_model",
            option = model_option,
            present = "claude-sonnet",
            present_name = "Sonnet",
        },
        {
            method = "get_thought_level",
            option = thought_option,
            present = "normal",
            present_name = "Normal",
        },
    }) do
        describe(case.method, function()
            it("returns matching option by value", function()
                config_options:set_options({ case.option })

                local result =
                    config_options[case.method](config_options, case.present)

                assert.is_not_nil(result)
                if result then
                    assert.equal(case.present_name, result.name)
                end
            end)

            it(
                "returns nil when unset, empty options, or value not found",
                function()
                    assert.is_nil(
                        config_options[case.method](
                            config_options,
                            case.present
                        )
                    )

                    local empty = vim.tbl_extend("force", case.option, {
                        options = {},
                    }) --[[@as agentic.acp.ConfigOption]]
                    config_options:set_options({ empty })
                    assert.is_nil(
                        config_options[case.method](
                            config_options,
                            case.present
                        )
                    )

                    config_options:set_options({ case.option })
                    assert.is_nil(
                        config_options[case.method](
                            config_options,
                            "nonexistent"
                        )
                    )
                end
            )
        end)
    end

    describe("get_mode_name", function()
        it("returns name from config option mode", function()
            config_options:set_options({ mode_option })

            assert.equal("Plan", config_options:get_mode_name("plan"))
        end)

        it("returns name from legacy mode", function()
            config_options.legacy_agent_modes:set_modes({
                availableModes = {
                    {
                        id = "legacy-mode",
                        name = "Legacy",
                        description = "Legacy mode",
                    },
                },
                currentModeId = "legacy-mode",
            })

            assert.equal("Legacy", config_options:get_mode_name("legacy-mode"))
        end)

        it("returns nil when mode not found in either source", function()
            config_options:set_options({ mode_option })

            assert.is_nil(config_options:get_mode_name("nonexistent"))
        end)
    end)

    --- set_initial_mode and set_initial_model share an identical early-return
    --- cascade. Decision table: target nil/empty -> nothing; not in any
    --- source -> notify+skip; matches current -> skip; in legacy -> handler
    --- with is_legacy=true; in config options -> handler with is_legacy=false.
    for _, case in ipairs({
        {
            method = "set_initial_mode",
            option = mode_option,
            current = "normal",
            other_value = "plan",
            legacy_setter = "legacy_agent_modes",
            set_legacy = function(target)
                target.legacy_agent_modes:set_modes({
                    availableModes = {
                        {
                            id = "legacy-plan",
                            name = "Legacy Plan",
                            description = "",
                        },
                    },
                    currentModeId = "legacy-normal",
                })
            end,
            legacy_target = "legacy-plan",
        },
        {
            method = "set_initial_model",
            option = model_option,
            current = "claude-sonnet",
            other_value = "claude-opus",
            legacy_setter = "legacy_agent_models",
            set_legacy = function(target)
                target.legacy_agent_models:set_models({
                    availableModels = {
                        {
                            modelId = "legacy-opus",
                            name = "Legacy Opus",
                            description = "",
                        },
                    },
                    currentModelId = "legacy-sonnet",
                })
            end,
            legacy_target = "legacy-opus",
        },
    }) do
        describe(case.method, function()
            --- @type TestStub
            local notify_stub

            before_each(function()
                config_options:set_options({ case.option })
                notify_stub =
                    spy.stub(require("agentic.utils.logger"), "notify")
            end)

            after_each(function()
                notify_stub:revert()
            end)

            it(
                "calls handler with is_legacy=false when target is in config options",
                function()
                    local handler = spy.new(function() end)

                    config_options[case.method](
                        config_options,
                        case.other_value,
                        handler --[[@as function]]
                    )

                    assert.spy(handler).was.called(1)
                    assert.equal(case.other_value, handler.calls[1][1])
                    assert.is_false(handler.calls[1][2])
                end
            )

            it(
                "calls handler with is_legacy=true when target is only in legacy",
                function()
                    case.set_legacy(config_options)
                    local handler = spy.new(function() end)

                    config_options[case.method](
                        config_options,
                        case.legacy_target,
                        handler --[[@as function]]
                    )

                    assert.spy(handler).was.called(1)
                    assert.equal(case.legacy_target, handler.calls[1][1])
                    assert.is_true(handler.calls[1][2])
                end
            )

            it("skips handler when target matches currentValue", function()
                local handler = spy.new(function() end)

                config_options[case.method](
                    config_options,
                    case.current,
                    handler --[[@as function]]
                )

                assert.spy(handler).was.called(0)
                assert.stub(notify_stub).was.called(0)
            end)

            it("warns when target is not in any source", function()
                local handler = spy.new(function() end)

                config_options[case.method](
                    config_options,
                    "nonexistent",
                    handler --[[@as function]]
                )

                assert.spy(handler).was.called(0)
                assert.stub(notify_stub).was.called(1)
                assert.is_true(
                    string.find(notify_stub.calls[1][1], "nonexistent") ~= nil
                )
            end)

            it("does nothing when target is nil or empty", function()
                local handler = spy.new(function() end)

                config_options[case.method](
                    config_options,
                    nil,
                    handler --[[@as function]]
                )
                config_options[case.method](
                    config_options,
                    "",
                    handler --[[@as function]]
                )

                assert.spy(handler).was.called(0)
                assert.stub(notify_stub).was.called(0)
            end)

            it(
                "does not crash when no config options and no legacy entries exist",
                function()
                    local fresh = make_fresh()
                    local handler = spy.new(function() end)

                    assert.has_no_errors(function()
                        fresh[case.method](
                            fresh,
                            "nonexistent",
                            handler --[[@as function]]
                        )
                    end)

                    assert.spy(handler).was.called(0)
                    assert.stub(notify_stub).was.called(1)
                    assert.is_true(
                        string.find(notify_stub.calls[1][1], "unknown") ~= nil
                    )
                end
            )
        end)
    end

    describe("set_initial_model (model-specific)", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            config_options:set_options({ model_option })
            notify_stub = spy.stub(require("agentic.utils.logger"), "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it(
            "prefers config options over legacy when model exists in both",
            function()
                config_options.legacy_agent_models:set_models({
                    availableModels = {
                        {
                            modelId = "claude-opus",
                            name = "Legacy Opus",
                            description = "",
                        },
                    },
                    currentModelId = "legacy-default",
                })

                local handler = spy.new(function() end)

                config_options:set_initial_model(
                    "claude-opus",
                    handler --[[@as fun(model: string, is_legacy: boolean|nil): any]]
                )

                assert.spy(handler).was.called(1)
                assert.equal("claude-opus", handler.calls[1][1])
                assert.is_false(handler.calls[1][2])
            end
        )
    end)

    --- show_mode_selector and show_model_selector share legacy-fallback
    --- behavior. Parameterize the common cases; thought_level is separate
    --- because it has no legacy fallback.
    for _, case in ipairs({
        {
            method = "show_mode_selector",
            option = mode_option,
            second_value = "plan",
            no_support_msg = "mode switching",
            legacy_setter = function(target)
                target.legacy_agent_modes:set_modes({
                    availableModes = {
                        {
                            id = "legacy",
                            name = "Legacy",
                            description = "Legacy mode",
                        },
                        {
                            id = "legacy-2",
                            name = "Legacy 2",
                            description = "Another",
                        },
                    },
                    currentModeId = "legacy",
                })
            end,
            legacy_second = "legacy-2",
        },
        {
            method = "show_model_selector",
            option = model_option,
            second_value = "claude-opus",
            no_support_msg = "model switching",
            legacy_setter = function(target)
                target.legacy_agent_models:set_models({
                    availableModels = {
                        {
                            modelId = "default",
                            name = "Default",
                            description = "Default model",
                        },
                        {
                            modelId = "opus",
                            name = "Opus",
                            description = "Most capable",
                        },
                    },
                    currentModelId = "default",
                })
            end,
            legacy_second = "opus",
        },
    }) do
        describe(case.method, function()
            --- @type TestStub
            local select_stub

            before_each(function()
                config_options:set_options({ case.option })
                select_stub = spy.stub(vim.ui, "select")
            end)

            after_each(function()
                select_stub:revert()
            end)

            it(
                "returns true and opens vim.ui.select when config options exist",
                function()
                    local shown = config_options[case.method](
                        config_options,
                        function() end
                    )

                    assert.is_true(shown)
                    assert.stub(select_stub).was.called(1)
                end
            )

            it(
                "calls handler with selection and is_legacy=false on config-option pick",
                function()
                    local handler = spy.new(function() end)
                    select_stub:invokes(function(items, _opts, on_choice)
                        on_choice(items[2])
                    end)

                    config_options[case.method](
                        config_options,
                        handler --[[@as function]]
                    )

                    assert
                        .spy(handler).was
                        .called_with(case.second_value, false)
                end
            )

            it("does not call handler on current value or cancel", function()
                local handler = spy.new(function() end)

                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[1])
                end)
                config_options[case.method](
                    config_options,
                    handler --[[@as function]]
                )

                select_stub:invokes(function(_items, _opts, on_choice)
                    on_choice(nil)
                end)
                config_options[case.method](
                    config_options,
                    handler --[[@as function]]
                )

                assert.spy(handler).was.called(0)
            end)

            it(
                "falls back to legacy and wraps callback with is_legacy=true",
                function()
                    local fresh = make_fresh()
                    case.legacy_setter(fresh)

                    local handler = spy.new(function() end)
                    select_stub:invokes(function(items, _opts, on_choice)
                        on_choice(items[2])
                    end)

                    local shown =
                        fresh[case.method](fresh, handler --[[@as function]])

                    assert.is_true(shown)
                    assert.stub(select_stub).was.called(1)
                    assert
                        .spy(handler).was
                        .called_with(case.legacy_second, true)
                end
            )

            it(
                "returns false and notifies when no options exist at all",
                function()
                    local notify_stub =
                        spy.stub(require("agentic.utils.logger"), "notify")

                    local fresh = make_fresh()

                    assert.is_false(fresh[case.method](fresh, function() end))
                    assert.stub(select_stub).was.called(0)
                    assert.stub(notify_stub).was.called(1)
                    assert.truthy(
                        string.find(
                            notify_stub.calls[1][1],
                            case.no_support_msg
                        )
                    )
                    assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])

                    notify_stub:revert()
                end
            )
        end)
    end

    describe("set_legacy_models", function()
        it("stores legacy models info", function()
            config_options:set_legacy_models({
                availableModels = {
                    {
                        modelId = "opus",
                        name = "Opus",
                        description = "Most capable",
                    },
                },
                currentModelId = "opus",
            })

            local model = config_options.legacy_agent_models:get_model("opus")
            assert.is_not_nil(model)
            assert.equal(
                "opus",
                config_options.legacy_agent_models.current_model_id
            )
        end)
    end)

    describe("show_thought_level_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it("returns false and notifies when thought_level is unset", function()
            local notify_stub =
                spy.stub(require("agentic.utils.logger"), "notify")

            local result = config_options:show_thought_level_selector(
                function() end
            )

            assert.is_false(result)
            assert.equal(0, select_stub.call_count)
            assert.equal(1, notify_stub.call_count)
            assert.is_true(
                notify_stub.calls[1][1]:find("thought effort level switching")
                    ~= nil
            )
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])

            notify_stub:revert()
        end)

        it("opens the selector when options are present", function()
            config_options:set_options({ thought_option })

            local result = config_options:show_thought_level_selector(
                function() end
            )

            assert.is_true(result)
            assert.equal(1, select_stub.call_count)
        end)

        it("invokes handler with selected value (no is_legacy)", function()
            config_options:set_options({ multi_thought })

            local handler_spy = spy.new(function() end)

            select_stub:invokes(function(items, _opts, on_choice)
                for _, item in ipairs(items) do
                    if item.value == "high" then
                        on_choice(item)
                        return
                    end
                end
            end)

            config_options:show_thought_level_selector(
                handler_spy --[[@as function]]
            )

            assert.equal(1, handler_spy.call_count)
            assert.equal("high", handler_spy.calls[1][1])
            assert.is_false(handler_spy.calls[1][2])
        end)
    end)

    describe("set_initial_thought_level", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            config_options:set_options({ multi_thought })
            notify_stub = spy.stub(require("agentic.utils.logger"), "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        --- Decision table for the early-return cascade. Each row maps a
        --- target value to its expected (handler call_count, notify
        --- call_count) pair. `multi_thought.currentValue` is "low".
        for _, case in ipairs({
            { name = "nil target", target = nil, handler = 0, notify = 0 },
            { name = "empty target", target = "", handler = 0, notify = 0 },
            {
                name = "invalid target",
                target = "nonexistent",
                handler = 0,
                notify = 1,
            },
            {
                name = "target equals current",
                target = "low",
                handler = 0,
                notify = 0,
            },
            {
                name = "target valid and different",
                target = "max",
                handler = 1,
                notify = 0,
            },
        }) do
            it(case.name, function()
                local handler = spy.new(function() end)

                config_options:set_initial_thought_level(
                    case.target,
                    handler --[[@as function]]
                )

                assert.equal(case.handler, handler.call_count)
                assert.equal(case.notify, notify_stub.call_count)

                if case.handler == 1 then
                    assert.equal(case.target, handler.calls[1][1])
                end
            end)
        end

        it(
            "silently skips (no notify) when provider has no thought_level option",
            function()
                config_options:clear()
                local handler = spy.new(function() end)

                config_options:set_initial_thought_level(
                    "max",
                    handler --[[@as function]]
                )

                assert.equal(0, handler.call_count)
                assert.equal(0, notify_stub.call_count)
            end
        )
    end)

    describe("clear", function()
        it("resets all fields, legacy modes, and legacy models", function()
            config_options:set_options({
                mode_option,
                model_option,
                thought_option,
            })
            config_options.legacy_agent_modes:set_modes({
                availableModes = {
                    { id = "legacy", name = "Legacy", description = "" },
                },
                currentModeId = "legacy",
            })
            config_options.legacy_agent_models:set_models({
                availableModels = {
                    {
                        modelId = "opus",
                        name = "Opus",
                        description = "Most capable",
                    },
                },
                currentModelId = "opus",
            })

            config_options:clear()

            assert.is_nil(config_options.mode)
            assert.is_nil(config_options.model)
            assert.is_nil(config_options.thought_level)
            assert.is_nil(config_options.legacy_agent_modes:get_mode("legacy"))
            assert.is_nil(config_options.legacy_agent_modes.current_mode_id)
            assert.is_nil(config_options.legacy_agent_models:get_model("opus"))
            assert.is_nil(config_options.legacy_agent_models.current_model_id)
        end)
    end)
end)
