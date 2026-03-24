local assert = require("tests.helpers.assert")

describe("ChatHistory", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil
        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        package.loaded["agentic.ui.chat_history"] = nil
    end)

    describe("message operations", function()
        it("add_message preserves insertion order", function()
            local history = ChatHistory:new()

            history:add_message({
                type = "user",
                text = "First",
                timestamp = os.time(),
                provider_name = "test-provider",
            })
            history:add_message({
                type = "agent",
                text = "Second",
                provider_name = "test-provider",
            })

            assert.equal(2, #history.messages)
            assert.equal("user", history.messages[1].type)
            assert.equal("agent", history.messages[2].type)
        end)

        describe("append_agent_text", function()
            it("creates new or appends based on last message type", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Hello",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello", history.messages[1].text)

                history:append_agent_text({
                    type = "agent",
                    text = " World",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello World", history.messages[1].text)

                history:add_message({
                    type = "user",
                    text = "Hi",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                assert.equal(3, #history.messages)
                assert.equal("agent", history.messages[3].type)
            end)

            it("treats agent and thought as separate types", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "thought",
                    text = "Thinking...",
                    provider_name = "test-provider",
                })

                assert.equal(2, #history.messages)
                assert.equal("agent", history.messages[1].type)
                assert.equal("thought", history.messages[2].type)
            end)
        end)

        describe("update_tool_call", function()
            it("finds and merges tool_call by ID", function()
                local history = ChatHistory:new()

                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-123",
                    status = "pending",
                    kind = "read",
                })

                history:update_tool_call("tc-123", {
                    tool_call_id = "tc-123",
                    status = "completed",
                    body = { "content" },
                    type = "tool_call",
                })

                assert.equal("completed", history.messages[1].status)
                assert.is_not_nil(history.messages[1].body)
            end)

            it("does nothing if tool_call not found", function()
                local history = ChatHistory:new()
                history:add_message({
                    type = "user",
                    text = "Hello",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })

                history:update_tool_call(
                    "non-existent",
                    { status = "completed", type = "tool_call" }
                )

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)
        end)
    end)
end)
