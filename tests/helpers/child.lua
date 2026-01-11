-- Helper to create isolated child Neovim instances with plugin loaded

local MiniTest = require("mini.test")

--- @class tests.helpers.Child : MiniTest.child
--- @field setup fun() Restart child and load plugin

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
    end

    return child
end

return M
