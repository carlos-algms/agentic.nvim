local assert = require("tests.helpers.assert")
local child = require("tests.helpers.child").new()

describe("session_manager", function()
    before_each(function()
        child.setup()
    end)

    teardown(function()
        child.stop()
    end)

    it("initializes with mocked transport", function()
        child.lua([[
            local ACPTransportMock = require("tests.mocks.acp_transport_mock")
            package.loaded["agentic.acp.acp_transport"] = ACPTransportMock

            local SessionManager = require("agentic.session_manager")
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            _G.session_manager = SessionManager:new(tab_page_id)
        ]])

        local has_transport =
            child.lua_get([[_G.session_manager.agent.transport ~= nil]])
        assert.is_true(has_transport)
    end)
end)
