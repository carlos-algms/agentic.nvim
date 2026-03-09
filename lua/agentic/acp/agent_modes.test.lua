local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentModes", function()
    --- @type agentic.acp.AgentModes
    local AgentModes

    --- @type agentic.acp.AgentModes
    local agent_modes

    --- @type agentic.acp.ModesInfo
    local modes_info = {
        availableModes = {
            { id = "normal", name = "Normal", description = "Standard mode" },
            { id = "plan", name = "Plan", description = "Planning mode" },
            { id = "code", name = "Code", description = "Coding mode" },
        },
        currentModeId = "normal",
    }

    before_each(function()
        AgentModes = require("agentic.acp.agent_modes")
        agent_modes = AgentModes:new({}, function() end)
        agent_modes:set_modes(modes_info)
    end)

    describe("get_mode", function()
        it("returns mode with matching id", function()
            local result = agent_modes:get_mode("plan")

            assert.is_not_nil(result)
            if result ~= nil then
                assert.equal("plan", result.id)
                assert.equal("Plan", result.name)
            end
        end)

        it("returns nil for non-existent or empty modes", function()
            assert.is_nil(agent_modes:get_mode("nonexistent"))

            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })
            assert.is_nil(agent_modes:get_mode("any_id"))
        end)
    end)

    describe("show_mode_selector", function()
        --- @type TestSpy
        local callback_spy
        --- @type TestStub
        local select_stub

        before_each(function()
            callback_spy = spy.new(function() end)
            agent_modes =
                AgentModes:new({}, callback_spy --[[@as fun(mode_id: string)]])
            agent_modes:set_modes(modes_info)
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it("does nothing when modes list is empty", function()
            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })
            agent_modes:show_mode_selector()
            assert.stub(select_stub).was.called(0)
        end)

        it("calls callback with id and is_config_option=false", function()
            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[2])
            end)

            agent_modes:show_mode_selector()
            assert.spy(callback_spy).was.called_with("plan", false)
        end)

        it("does not call callback on current mode or cancel", function()
            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[1])
            end)
            agent_modes:show_mode_selector()

            select_stub:invokes(function(_items, _opts, on_choice)
                on_choice(nil)
            end)
            agent_modes:show_mode_selector()

            assert.spy(callback_spy).was.called(0)
        end)

        it("delegates to agent_config_options when present", function()
            local config_options_mock = {
                show_mode_selector = spy.new(function()
                    return true
                end),
            }
            agent_modes.agent_config_options = config_options_mock --[[@as agentic.acp.AgentConfigOptions]]

            agent_modes:show_mode_selector()

            assert.spy(config_options_mock.show_mode_selector).was.called(1)
            assert.stub(select_stub).was.called(0)
        end)

        it(
            "falls back to legacy modes when config_options returns false",
            function()
                local config_options_mock = {
                    show_mode_selector = spy.new(function()
                        return false
                    end),
                }
                agent_modes.agent_config_options = config_options_mock --[[@as agentic.acp.AgentConfigOptions]]

                agent_modes:show_mode_selector()

                assert.spy(config_options_mock.show_mode_selector).was.called(1)
                assert.stub(select_stub).was.called(1)
            end
        )
    end)

    describe("handle_agent_update_mode", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            local Logger = require("agentic.utils.logger")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it("updates current_mode_id and notifies on valid mode", function()
            local success = agent_modes:handle_agent_update_mode("code")

            assert.is_true(success)
            assert.equal("code", agent_modes.current_mode_id)
            assert.stub(notify_stub).was.called(1)
            assert.is_true(string.find(notify_stub.calls[1][1], "code") ~= nil)
        end)

        it("returns false and warns for nil or invalid mode_id", function()
            assert.is_false(agent_modes:handle_agent_update_mode(nil))
            assert.is_false(agent_modes:handle_agent_update_mode("nonexistent"))

            assert.equal("normal", agent_modes.current_mode_id)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)

        it("returns false when modes list is empty", function()
            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })

            assert.is_false(agent_modes:handle_agent_update_mode("plan"))
        end)
    end)

    describe("clear", function()
        it("resets agent_config_options and modes", function()
            --- @diagnostic disable-next-line: missing-fields
            agent_modes.agent_config_options = {} --[[@as agentic.acp.AgentConfigOptions]]

            agent_modes:clear()

            assert.is_nil(agent_modes.agent_config_options)
            assert.same({}, agent_modes.modes)
        end)
    end)
end)
