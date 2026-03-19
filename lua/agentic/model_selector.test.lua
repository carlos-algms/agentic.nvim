--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

describe("model selector", function()
    --- @type TestStub
    local multi_keymap_stub
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local select_stub
    --- @type agentic.SessionManager
    local session
    --- @type integer
    local test_bufnr
    --- @type fun(model_id: string, is_legacy: boolean)
    local handle_model_change

    local format_all = function(items, opts)
        return vim.tbl_map(function(item)
            return opts.format_item(item)
        end, items)
    end

    before_each(function()
        local AgentConfigOptions = require("agentic.acp.agent_config_options")
        local BufHelpers = require("agentic.utils.buf_helpers")

        multi_keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")
        notify_stub = spy.stub(Logger, "notify")
        select_stub = spy.stub(vim.ui, "select")
        test_bufnr = vim.api.nvim_create_buf(false, true)

        session = {
            session_id = "session-1",
            agent = {},
            _handle_model_change = SessionManager._handle_model_change,
            _handle_new_config_options = SessionManager._handle_new_config_options,
        } --[[@as agentic.SessionManager]]

        session.config_options = AgentConfigOptions:new(
            { chat = test_bufnr },
            function() end,
            function(model_id, is_legacy)
                session:_handle_model_change(model_id, is_legacy)
            end
        )

        handle_model_change = function(model_id, is_legacy)
            session:_handle_model_change(model_id, is_legacy)
        end
    end)

    after_each(function()
        multi_keymap_stub:revert()
        notify_stub:revert()
        select_stub:revert()
        vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end)

    it(
        "re-marks newly selected model when provider returns configOptions",
        function()
            session.config_options:set_options({
                {
                    id = "model-1",
                    category = "model",
                    currentValue = "model2",
                    description = "Model selection",
                    name = "Model",
                    options = {
                        {
                            value = "model1",
                            name = "Model 1",
                            description = "Adds zest",
                        },
                        {
                            value = "model2",
                            name = "Model 2",
                            description = "The default one",
                        },
                        {
                            value = "model3",
                            name = "Model 3",
                            description = "Runs on oil and vinegar",
                        },
                    },
                },
            })

            -- Replace set_config_option with a custom implementation that returns configOptions
            session.agent.set_config_option = function(
                _self,
                _session_id,
                _config_id,
                value,
                callback
            )
                callback({
                    configOptions = {
                        {
                            id = "model-1",
                            category = "model",
                            currentValue = value,
                            description = "Model selection",
                            name = "Model",
                            options = {
                                { value = "model1", name = "Model 1" },
                                { value = "model2", name = "Model 2" },
                                { value = "model3", name = "Model 3" },
                            },
                        },
                    },
                }, nil)
            end

            --- @type string[]
            local second_render = {}

            -- Select model1 (initially model2 is selected)
            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[1])
            end)

            session.config_options:show_model_selector(handle_model_change)

            -- Re-open to verify it was updated from configOptions
            select_stub:invokes(function(items, opts, on_choice)
                second_render = format_all(items, opts)
                on_choice(nil)
            end)

            session.config_options:show_model_selector(handle_model_change)

            assert.same({
                "● Model 1",
                "  Model 2",
                "  Model 3",
            }, second_render)
        end
    )

    it("re-marks the newly selected legacy model when reopened", function()
        local set_model_spy = spy.new(
            function(_self, _session_id, _model_id, callback)
                callback(nil, nil)
            end
        )
        session.agent.set_model = set_model_spy

        session.config_options:set_legacy_models({
            availableModels = {
                {
                    modelId = "model1",
                    name = "Model 1",
                    description = "Adds zest",
                },
                {
                    modelId = "model2",
                    name = "Model 2",
                    description = "The default one",
                },
            },
            currentModelId = "model2",
        })

        --- @type string[]
        local first_render = {}
        --- @type string[]
        local second_render = {}

        select_stub:invokes(function(items, opts, on_choice)
            first_render = format_all(items, opts)
            on_choice(items[1]) -- select model1
        end)

        session.config_options:show_model_selector(handle_model_change)

        select_stub:invokes(function(items, opts, on_choice)
            second_render = format_all(items, opts)
            on_choice(nil)
        end)

        session.config_options:show_model_selector(handle_model_change)

        assert.same({
            "  Model 1: Adds zest",
            "● Model 2: The default one",
        }, first_render)

        assert.spy(set_model_spy).was.called(1)
        assert.equal("session-1", set_model_spy.calls[1][2])
        assert.equal("model1", set_model_spy.calls[1][3])

        assert.same({
            "● Model 1: Adds zest",
            "  Model 2: The default one",
        }, second_render)
    end)
end)
