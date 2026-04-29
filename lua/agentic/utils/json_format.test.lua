local assert = require("tests.helpers.assert")

describe("JsonFormat", function()
    --- @type agentic.utils.JsonFormat
    local JsonFormat

    before_each(function()
        package.loaded["agentic.utils.json_format"] = nil
        JsonFormat = require("agentic.utils.json_format")
    end)

    describe("format_line", function()
        it("returns short strings unchanged", function()
            local input = '{"a":1}'
            assert.equal(input, JsonFormat.format_line(input))
        end)

        it("returns non-JSON looking strings unchanged", function()
            local input = string.rep("x", 200)
            assert.equal(input, JsonFormat.format_line(input))
        end)

        it("returns plain prose unchanged", function()
            local input = "I'm going to fetch this and then look up the value "
                .. string.rep("text ", 30)
            assert.equal(input, JsonFormat.format_line(input))
        end)

        it("returns invalid JSON unchanged", function()
            local input = "{" .. string.rep("not valid json ", 10) .. "}"
            assert.equal(input, JsonFormat.format_line(input))
        end)

        it("pretty-prints a long JSON object", function()
            local long_value = string.rep("v", 100)
            local input = '{"key":"' .. long_value .. '","other":42}'
            local result = JsonFormat.format_line(input)

            assert.is_true(result:find("\n") ~= nil)
            assert.is_true(result:sub(1, 1) == "{")
            assert.is_true(result:sub(-1) == "}")

            local ok, decoded = pcall(vim.json.decode, result)
            assert.is_true(ok)
            assert.equal(long_value, decoded.key)
            assert.equal(42, decoded.other)
        end)

        it("pretty-prints a long JSON array", function()
            local input = "["
                .. string.rep('"' .. string.rep("a", 20) .. '",', 10)
            input = input:sub(1, -2) .. "]"

            local result = JsonFormat.format_line(input)
            assert.is_true(result:find("\n") ~= nil)
            assert.is_true(result:sub(1, 1) == "[")
            assert.is_true(result:sub(-1) == "]")
        end)

        it("is idempotent on already-formatted JSON", function()
            local long_value = string.rep("v", 100)
            local input = '{"key":"' .. long_value .. '"}'
            local once = JsonFormat.format_line(input)
            local twice = JsonFormat.format_line(once)
            assert.equal(once, twice)
        end)
    end)

    describe("format_lines", function()
        it("returns multi-line input unchanged", function()
            local input = { "line one", "line two" }
            assert.same(input, JsonFormat.format_lines(input))
        end)

        it("returns empty input unchanged", function()
            local input = {}
            assert.same(input, JsonFormat.format_lines(input))
        end)

        it("formats a single-line JSON body into many lines", function()
            local long_value = string.rep("v", 100)
            local input = { '{"key":"' .. long_value .. '","x":1}' }
            local result = JsonFormat.format_lines(input)
            assert.is_true(#result > 1)
        end)

        it("returns single non-JSON line unchanged", function()
            local input = { "I'm going to fetch this" }
            assert.same(input, JsonFormat.format_lines(input))
        end)
    end)
end)
