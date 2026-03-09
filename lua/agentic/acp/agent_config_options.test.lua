local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentConfigOptions", function()
    --- @type agentic.acp.AgentConfigOptions
    local AgentConfigOptions

    --- @type agentic.acp.AgentConfigOptions
    local config_options

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
            {
                value = "plan",
                name = "Plan",
                description = "Planning mode",
            },
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

    before_each(function()
        AgentConfigOptions = require("agentic.acp.agent_config_options")
        config_options = AgentConfigOptions:new()
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

        it("ignores unknown categories", function()
            --- @type agentic.acp.ConfigOption
            local unknown = vim.tbl_extend("force", mode_option, {
                category = "unknown_cat",
            }) --[[@as agentic.acp.ConfigOption]]

            config_options:set_options({ unknown })

            assert.is_nil(config_options.mode)
        end)
    end)

    describe("get_mode", function()
        it("returns matching option by value", function()
            config_options:set_options({ mode_option })

            local result = config_options:get_mode("plan")

            assert.is_not_nil(result)
            if result then
                assert.equal("Plan", result.name)
            end
        end)

        it(
            "returns nil when mode is unset, empty, or value not found",
            function()
                assert.is_nil(config_options:get_mode("normal"))

                local empty_mode = vim.tbl_extend("force", mode_option, {
                    options = {},
                }) --[[@as agentic.acp.ConfigOption]]
                config_options:set_options({ empty_mode })
                assert.is_nil(config_options:get_mode("normal"))

                config_options:set_options({ mode_option })
                assert.is_nil(config_options:get_mode("nonexistent"))
            end
        )
    end)

    describe("set_initial_mode", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            config_options:set_options({ mode_option })
            local Logger = require("agentic.utils.logger")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it("calls handler when default_mode differs from current", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "plan",
                handler --[[@as fun(mode: string): any]]
            )

            assert.spy(handler).was.called_with("plan")
        end)

        it("skips handler when default_mode matches currentValue", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "normal",
                handler --[[@as fun(mode: string): any]]
            )

            assert.spy(handler).was.called(0)
        end)

        it("warns when default_mode is not in options", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "nonexistent",
                handler --[[@as fun(mode: string): any]]
            )

            assert.spy(handler).was.called(0)
            assert.stub(notify_stub).was.called(1)
            assert.is_true(
                string.find(notify_stub.calls[1][1], "nonexistent") ~= nil
            )
        end)

        it("does nothing when default_mode is nil or empty", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                nil,
                handler --[[@as fun(mode: string): any]]
            )
            config_options:set_initial_mode(
                "",
                handler --[[@as fun(mode: string): any]]
            )

            assert.spy(handler).was.called(0)
            assert.stub(notify_stub).was.called(0)
        end)
    end)

    describe("show_mode_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            config_options:set_options({ mode_option })
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it("returns false when mode is unset or has no options", function()
            local handler = function() end
            local fresh = AgentConfigOptions:new()
            assert.is_false(fresh:show_mode_selector(handler))

            local empty_mode = vim.tbl_extend("force", mode_option, {
                options = {},
            }) --[[@as agentic.acp.ConfigOption]]
            fresh:set_options({ empty_mode })
            assert.is_false(fresh:show_mode_selector(handler))

            assert.stub(select_stub).was.called(0)
        end)

        it("opens vim.ui.select and returns true", function()
            local shown = config_options:show_mode_selector(function() end)

            assert.is_true(shown)
            assert.stub(select_stub).was.called(1)
        end)

        it(
            "calls handler with value and is_config_option=true on selection",
            function()
                local handler = spy.new(function() end)
                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                config_options:show_mode_selector(
                    handler --[[@as fun(mode: string, is_config_option: boolean): any]]
                )

                assert.spy(handler).was.called_with("plan", true)
            end
        )

        it("does not call handler on current value or cancel", function()
            local handler = spy.new(function() end)

            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[1])
            end)
            config_options:show_mode_selector(
                handler --[[@as fun(mode: string, is_config_option: boolean): any]]
            )

            select_stub:invokes(function(_items, _opts, on_choice)
                on_choice(nil)
            end)
            config_options:show_mode_selector(
                handler --[[@as fun(mode: string, is_config_option: boolean): any]]
            )

            assert.spy(handler).was.called(0)
        end)
    end)
end)
