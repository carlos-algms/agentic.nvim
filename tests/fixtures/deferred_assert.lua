-- Run by tests/unit/test_deferred_guard.lua in a separate Neovim. Not
-- collected by the suite: the file name matches no test pattern.
local assert = require("tests.helpers.assert")

describe("deferred assertion fixture", function()
    it("asserts inside vim.schedule", function()
        vim.schedule(function()
            assert.equal(1, 1)
        end)
    end)
end)
