-- tests/helpers/child.lua
-- Helper to create isolated child Neovim instances with plugin loaded

local MiniTest = require("mini.test")

local M = {}

--- Create a new child Neovim instance with the plugin pre-loaded
--- @return table child Child Neovim instance with setup() method
function M.new()
    local child = MiniTest.new_child_neovim()
    local root_dir = vim.fn.getcwd()

    --- Restart child and load plugin
    function child.setup()
        child.restart({ "-u", "NONE" })
        child.lua("vim.opt.rtp:prepend(...)", { root_dir })
    end

    return child
end

return M
