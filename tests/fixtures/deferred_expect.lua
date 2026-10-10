-- Run by tests/unit/test_deferred_guard.lua in a separate Neovim. Not
-- collected by the suite: the file name matches no test pattern.
local MiniTest = require("mini.test")

describe("deferred MiniTest.expect fixture", function()
    it("calls MiniTest.expect inside vim.schedule", function()
        vim.schedule(function()
            MiniTest.expect.equality(1, 1)
        end)
    end)
end)
