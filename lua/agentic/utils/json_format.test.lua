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

        it(
            "expands an escaped newline in a string value into a real line break",
            function()
                local padding = string.rep("v", 60)
                local input = '{"summary":"first paragraph '
                    .. padding
                    .. '\\n\\nsecond paragraph","x":1}'
                local result = JsonFormat.format_line(input)

                assert.is_nil(result:find("\\n", 1, true))
                assert.is_true(result:find("first paragraph") ~= nil)
                assert.is_true(result:find("second paragraph") ~= nil)
            end
        )
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

        it(
            "pretty-prints a JSON line wrapped in a markdown code fence",
            function()
                local long_value = string.rep("v", 100)
                local json_text = '{"key":"' .. long_value .. '","x":1}'
                local input = { "```console", json_text, "```" }

                local result = JsonFormat.format_lines(input)

                assert.is_true(#result > 3)
                assert.equal("```console", result[1])
                assert.equal("```", result[#result])
                assert.equal("{", result[2])
            end
        )

        it("pretty-prints a JSON line that follows a prose line", function()
            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":1}'
            local input = { "Here is the response:", json_text }

            local result = JsonFormat.format_lines(input)

            assert.is_true(#result > 2)
            assert.equal("Here is the response:", result[1])
            assert.equal("{", result[2])
        end)

        it("is idempotent on already-formatted bodies", function()
            local long_value = string.rep("v", 100)
            local input = { '{"key":"' .. long_value .. '","x":1}' }

            local once = JsonFormat.format_lines(input)
            local twice = JsonFormat.format_lines(once)

            assert.same(once, twice)
        end)

        it(
            "expands an escaped newline in a string value across multiple output lines",
            function()
                local padding = string.rep("v", 60)
                local input = {
                    '{"summary":"first paragraph '
                        .. padding
                        .. '\\n\\nsecond paragraph","x":1}',
                }
                local result = JsonFormat.format_lines(input)

                for _, line in ipairs(result) do
                    assert.is_nil(line:find("\\n", 1, true))
                end

                local joined = table.concat(result, "\n")
                assert.is_true(joined:find("first paragraph") ~= nil)
                assert.is_true(joined:find("second paragraph") ~= nil)
                -- x:1 must still be present and intact after the string field
                assert.is_true(joined:find('"x": 1') ~= nil)
            end
        )
    end)

    describe("format_value", function()
        it("expands a short object below the length threshold", function()
            local result = JsonFormat.format_value({ command = "ls -la" })

            assert.is_true(result:find("\n") ~= nil)
            assert.equal("{", result:sub(1, 1))
            assert.is_true(result:find('"command": "ls %-la"') ~= nil)
        end)

        it("emits sorted keys on their own indented lines", function()
            local result = JsonFormat.format_value({
                command = "ls",
                description = "List files",
            })

            local lines = vim.split(result, "\n")
            assert.equal('  "command": "ls",', lines[2])
            assert.equal('  "description": "List files"', lines[3])
        end)

        it("returns {} for an empty dict without crashing", function()
            assert.equal("{}", JsonFormat.format_value(vim.empty_dict()))
        end)

        it("expands nested objects", function()
            local result = JsonFormat.format_value({
                outer = { inner = "value" },
            })

            assert.is_true(result:find('"outer": {') ~= nil)
            assert.is_true(result:find('"inner": "value"') ~= nil)
        end)

        it("renders array-shaped tables", function()
            local result = JsonFormat.format_value({ "a", "b" })

            assert.equal("[", result:sub(1, 1))
            assert.is_true(result:find('"a"') ~= nil)
            assert.is_true(result:find('"b"') ~= nil)
        end)

        it("encodes vim.NIL as null", function()
            local result = JsonFormat.format_value({ value = vim.NIL })

            assert.is_true(result:find('"value": null') ~= nil)
        end)

        it("encodes boolean and number values", function()
            local result = JsonFormat.format_value({ flag = true, count = 3 })

            assert.is_true(result:find('"count": 3') ~= nil)
            assert.is_true(result:find('"flag": true') ~= nil)
        end)

        it(
            "renders embedded newlines in a string value as real line breaks, not \\n",
            function()
                local result = JsonFormat.format_value({
                    summary = "first paragraph\n\nsecond paragraph",
                })

                assert.is_nil(result:find("\\n", 1, true))

                local lines = vim.split(result, "\n")
                assert.equal('  "summary": "first paragraph', lines[2])
                -- Blank paragraph-separator line still carries the
                -- continuation indent (one level deeper than the key).
                assert.equal("    ", lines[3])
                assert.equal('    second paragraph"', lines[4])
                assert.equal("}", lines[5])
            end
        )

        it(
            "keeps sibling keys intact around a multi-line string value",
            function()
                local result = JsonFormat.format_value({
                    ok = true,
                    summary = "line one\nline two",
                })

                assert.is_true(result:find('"ok": true', 1, true) ~= nil)
                assert.is_true(result:find("line one", 1, true) ~= nil)
                assert.is_true(result:find("line two", 1, true) ~= nil)
            end
        )
    end)
end)
