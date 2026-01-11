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
                assert.equal("Planning mode", result.description)
            end
        end)

        it("returns nil when mode id does not exist", function()
            local result = agent_modes:get_mode("nonexistent")
            assert.is_nil(result)
        end)

        it("returns nil when modes list is empty", function()
            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })
            local result = agent_modes:get_mode("any_id")
            assert.is_nil(result)
        end)

        it("returns correct mode from multiple modes", function()
            local result = agent_modes:get_mode("code")

            assert.is_not_nil(result)

            if result ~= nil then
                assert.equal("code", result.id)
                assert.equal("Code", result.name)
            end
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

        it("calls vim.ui.select with modes list", function()
            agent_modes:show_mode_selector()
            assert.stub(select_stub).was.called(1)
        end)

        it("calls callback when selecting different mode", function()
            select_stub:invokes(function(items, opts, on_choice)
                on_choice(items[2]) -- Select "plan"
            end)

            agent_modes:show_mode_selector()
            assert.spy(callback_spy).was.called_with("plan")
        end)

        it("does not call callback when selecting current mode", function()
            select_stub:invokes(function(items, opts, on_choice)
                on_choice(items[1]) -- Select "normal" (current)
            end)

            agent_modes:show_mode_selector()
            assert.spy(callback_spy).was.called(0)
        end)

        it("does not call callback when user cancels", function()
            select_stub:invokes(function(items, opts, on_choice)
                on_choice(nil)
            end)

            agent_modes:show_mode_selector()
            assert.spy(callback_spy).was.called(0)
        end)
    end)
end)
