-- Helper to create isolated child Neovim instances with plugin loaded

local MiniTest = require("mini.test")

--- @class tests.helpers.Child : MiniTest.child
--- @field setup fun() Restart child and load plugin and run agentic.setup() to run auto commands and configurations
--- @field flush fun() Flush pending scheduled callbacks in child neovim and wait a bit to ensure they are processed

--- @class tests.helpers.ChildModule
local M = {}

--- Create a new child Neovim instance with the plugin pre-loaded
--- @return tests.helpers.Child child Child Neovim instance with setup() method
function M.new()
    local child = MiniTest.new_child_neovim() --[[@as tests.helpers.Child]]
    local root_dir = vim.fn.getcwd()

    function child.setup()
        child.restart({ "-u", "NONE" })
        child.lua("vim.opt.rtp:prepend(...)", { root_dir })

        child.lua([[
            local ACPTransportMock = require("tests.mocks.acp_transport_mock")
            package.loaded["agentic.acp.acp_transport"] = ACPTransportMock
        ]])

        child.lua([[
            local ACPHealthMock = require("tests.mocks.acp_health_mock")
            package.loaded["agentic.acp.acp_health"] = ACPHealthMock
        ]])

        child.lua([[
            require("agentic").setup()
        ]])
    end

    function child.flush()
        child.lua([[
          vim.cmd("redraw")
        ]])

        child.api.nvim_eval("1")
    end

    return child
end

return M
