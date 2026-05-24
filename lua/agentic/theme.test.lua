local assert = require("tests.helpers.assert")

describe("agentic.theme", function()
    local Theme = require("agentic.theme")

    describe("get_language_from_path", function()
        it("maps .md to 'markdown' (tree-sitter has no 'md' alias)", function()
            assert.equal("markdown", Theme.get_language_from_path("README.md"))
        end)

        it("returns extension as-is when not in lang_map", function()
            assert.equal("lua", Theme.get_language_from_path("init.lua"))
        end)

        it("applies lang_map aliases", function()
            assert.equal("python", Theme.get_language_from_path("a.py"))
            assert.equal("bash", Theme.get_language_from_path("a.sh"))
        end)

        it("returns empty string for path without extension", function()
            assert.equal("", Theme.get_language_from_path("Makefile"))
        end)
    end)
end)
