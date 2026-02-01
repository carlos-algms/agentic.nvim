-- luacheck: globals vim
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("ChatHistory", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory
    local original_storage_path
    local test_dir

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil

        test_dir = vim.fn.tempname()
        vim.fn.mkdir(test_dir, "p")

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = test_dir

        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        vim.fn.delete(test_dir, "rf")
        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.ui.chat_history"] = nil
    end)

    describe("get_project_folder", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it("normalizes slashes, spaces, and colons to underscores", function()
            local test_cases = {
                {
                    path = "/Users/me/projects/myapp",
                    expected = "Users_me_projects_myapp",
                },
                {
                    path = "/Users/my user/my projects",
                    expected = "my_user.*my_projects",
                },
                {
                    path = "C:\\Users\\me\\projects",
                    expected = "C_.*Users_me_projects",
                },
            }

            for _, tc in ipairs(test_cases) do
                vim.uv.cwd = function()
                    return tc.path
                end
                local folder = ChatHistory.get_project_folder()
                assert.truthy(folder:match(tc.expected))
                assert.is_nil(folder:match("^_"))
            end
        end)

        it("appends 8-char SHA256 hash suffix", function()
            vim.uv.cwd = function()
                return "/test/path"
            end

            local folder = ChatHistory.get_project_folder()
            local hash_part = folder:match("_(%x+)$")

            assert.is_not_nil(hash_part)
            assert.equal(8, #hash_part)
        end)

        it("produces different hashes for different paths", function()
            --- @diagnostic disable-next-line: duplicate-set-field
            vim.uv.cwd = function()
                return "/path/one"
            end
            local folder1 = ChatHistory.get_project_folder()

            --- @diagnostic disable-next-line: duplicate-set-field
            vim.uv.cwd = function()
                return "/path/two"
            end
            local folder2 = ChatHistory.get_project_folder()

            assert.are_not.equal(folder1, folder2)
        end)
    end)

    describe("get_file_path", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it(
            "combines storage_path, project_folder, and session_id.json",
            function()
                local path = ChatHistory.get_file_path("session-abc")
                local project_folder = ChatHistory.get_project_folder()

                assert.truthy(path:match("^" .. vim.pesc(test_dir)))
                assert.truthy(path:find(project_folder, 1, true))
                assert.truthy(path:match("session%-abc%.json$"))
            end
        )
    end)

    describe("message operations", function()
        it("add_message preserves insertion order", function()
            local history = ChatHistory:new()

            history:add_message({ type = "user", text = "First" })
            history:add_message({ type = "agent", text = "Second" })

            assert.equal(2, #history.messages)
            assert.equal("user", history.messages[1].type)
            assert.equal("agent", history.messages[2].type)
        end)

        describe("append_agent_text", function()
            it("creates new or appends based on last message type", function()
                local history = ChatHistory:new()

                history:append_agent_text("agent", "Hello")
                assert.equal(1, #history.messages)
                assert.equal("Hello", history.messages[1].text)

                history:append_agent_text("agent", " World")
                assert.equal(1, #history.messages)
                assert.equal("Hello World", history.messages[1].text)

                history:add_message({ type = "user", text = "Hi" })
                history:append_agent_text("agent", "Response")
                assert.equal(3, #history.messages)
                assert.equal("agent", history.messages[3].type)
            end)

            it("treats agent and thought as separate types", function()
                local history = ChatHistory:new()

                history:append_agent_text("agent", "Response")
                history:append_agent_text("thought", "Thinking...")

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
                    status = "completed",
                    body = { "file content" },
                })

                assert.equal("completed", history.messages[1].status)
                assert.is_not_nil(history.messages[1].body)
            end)

            it("does nothing if tool_call not found", function()
                local history = ChatHistory:new()
                history:add_message({ type = "user", text = "Hello" })

                history:update_tool_call(
                    "non-existent",
                    { status = "completed" }
                )

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)

            it("updates latest tool_call when duplicates exist", function()
                local history = ChatHistory:new()

                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-123",
                    status = "pending",
                    kind = "read",
                })
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-123",
                    status = "pending",
                    kind = "edit",
                })

                history:update_tool_call("tc-123", { status = "completed" })

                assert.equal("pending", history.messages[1].status)
                assert.equal("completed", history.messages[2].status)
            end)
        end)
    end)

    describe("save", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it("creates directory and JSON file with correct structure", function()
            local history = ChatHistory:new()
            history.session_id = "save-test-123"
            history:add_message({ type = "user", text = "Test message" })

            local done = false
            local save_err = nil
            local callback_spy = spy.new(function(err)
                save_err = err
                done = true
            end)

            history:save(callback_spy --[[@as function]])

            vim.wait(1000, function()
                return done
            end)

            assert.is_nil(save_err)
            assert.spy(callback_spy).was.called(1)

            local path = ChatHistory.get_file_path("save-test-123")
            local dir = vim.fn.fnamemodify(path, ":h")
            assert.equal(1, vim.fn.isdirectory(dir))

            local content = vim.fn.readfile(path)
            local parsed = vim.json.decode(table.concat(content, "\n"))

            assert.equal("save-test-123", parsed.session_id)
            assert.equal("Test message", parsed.title)
            assert.is_not_nil(parsed.timestamp)
            assert.equal(1, #parsed.messages)
        end)
    end)

    describe("load", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it("restores ChatHistory instance from saved JSON", function()
            local original = ChatHistory:new()
            original.session_id = "load-test-123"
            original:add_message({ type = "user", text = "Saved message" })

            local saved = false
            original:save(function()
                saved = true
            end)

            vim.wait(1000, function()
                return saved
            end)

            local loaded = nil
            local load_err = nil
            local loaded_done = false

            ChatHistory.load("load-test-123", function(history, err)
                loaded = history
                load_err = err
                loaded_done = true
            end)

            vim.wait(1000, function()
                return loaded_done
            end)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal("load-test-123", loaded.session_id)
            assert.equal(original.timestamp, loaded.timestamp)
            assert.equal(1, #loaded.messages)
            --- @diagnostic disable-next-line: need-check-nil
            assert.equal("Saved message", loaded.messages[1].text)
        end)

        it("returns error for missing or corrupted files", function()
            local test_cases = {
                { session_id = "non-existent", setup = function() end },
                {
                    session_id = "corrupted-test",
                    setup = function()
                        local path = ChatHistory.get_file_path("corrupted-test")
                        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
                        vim.fn.writefile({ "not valid json {{{" }, path)
                    end,
                },
            }

            for _, tc in ipairs(test_cases) do
                tc.setup()

                local loaded = nil
                local load_err = nil
                local done = false

                ChatHistory.load(tc.session_id, function(history, err)
                    loaded = history
                    load_err = err
                    done = true
                end)

                vim.wait(1000, function()
                    return done
                end)

                assert.is_nil(loaded)
                assert.is_not_nil(load_err)
            end
        end)
    end)

    describe("list_sessions", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it("returns empty array when no sessions exist", function()
            local sessions = nil
            local done = false

            ChatHistory.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(0, #sessions)
        end)

        it("returns all saved sessions in project folder", function()
            local session1 = ChatHistory:new()
            session1.session_id = "session-1"
            session1:add_message({ type = "user", text = "First session" })

            local session2 = ChatHistory:new()
            session2.session_id = "session-2"
            session2:add_message({ type = "user", text = "Second session" })

            local saved1, saved2 = false, false
            session1:save(function()
                saved1 = true
            end)
            session2:save(function()
                saved2 = true
            end)

            vim.wait(1000, function()
                return saved1 and saved2
            end)

            local sessions = nil
            local done = false

            ChatHistory.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(2, #sessions)

            local ids = {}
            for _, s in ipairs(sessions or {}) do
                ids[s.session_id] = true
            end
            assert.is_true(ids["session-1"])
            assert.is_true(ids["session-2"])
        end)
    end)
end)
