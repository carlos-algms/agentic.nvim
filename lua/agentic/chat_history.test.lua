-- luacheck: globals vim
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("ChatHistory", function()
    --- @type agentic.ChatHistory
    local ChatHistory

    before_each(function()
        package.loaded["agentic.chat_history"] = nil
        ChatHistory = require("agentic.chat_history")
    end)

    describe("constructor", function()
        it("creates instance with session_id and empty messages", function()
            local history = ChatHistory:new("test-session-123")

            assert.equal("test-session-123", history.session_id)
            assert.is_table(history.messages)
            assert.equal(0, #history.messages)
            assert.is_not_nil(history.timestamp)
        end)

        it("accepts optional dir_path", function()
            local history = ChatHistory:new("test-session", "/custom/path")

            --- @diagnostic disable-next-line: invisible
            assert.equal("/custom/path", history._dir_path)
        end)
    end)

    describe("_get_project_folder", function()
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
        end)

        it("normalizes path with slashes", function()
            vim.uv.cwd = function()
                return "/Users/me/projects/myapp"
            end

            local history = ChatHistory:new("test")
            --- @diagnostic disable-next-line: invisible
            local folder = history:_get_project_folder()

            -- Should not start with underscore
            assert.is_nil(folder:match("^_"))
            -- Should contain normalized path
            assert.truthy(folder:match("Users_me_projects_myapp"))
        end)

        it("normalizes path with spaces", function()
            vim.uv.cwd = function()
                return "/Users/my user/my projects"
            end

            local history = ChatHistory:new("test")
            --- @diagnostic disable-next-line: invisible
            local folder = history:_get_project_folder()

            assert.truthy(folder:match("my_user"))
            assert.truthy(folder:match("my_projects"))
        end)

        it("normalizes path with colons (Windows)", function()
            vim.uv.cwd = function()
                return "C:\\Users\\me\\projects"
            end

            local history = ChatHistory:new("test")
            --- @diagnostic disable-next-line: invisible
            local folder = history:_get_project_folder()

            assert.truthy(folder:match("C_"))
            assert.truthy(folder:match("Users_me_projects"))
        end)

        it("appends 8-char SHA256 hash suffix", function()
            vim.uv.cwd = function()
                return "/test/path"
            end

            local history = ChatHistory:new("test")
            --- @diagnostic disable-next-line: invisible
            local folder = history:_get_project_folder()

            -- Should end with _<8 hex chars>
            local hash_part = folder:match("_(%x+)$")
            assert.is_not_nil(hash_part)
            assert.equal(8, #hash_part)
        end)

        it("produces different hashes for different paths", function()
            local folder1, folder2

            --- @diagnostic disable-next-line: duplicate-set-field
            vim.uv.cwd = function()
                return "/path/one"
            end
            --- @diagnostic disable-next-line: invisible
            folder1 = ChatHistory:new("test"):_get_project_folder()

            --- @diagnostic disable-next-line: duplicate-set-field
            vim.uv.cwd = function()
                return "/path/two"
            end
            --- @diagnostic disable-next-line: invisible
            folder2 = ChatHistory:new("test"):_get_project_folder()

            assert.are_not.equal(folder1, folder2)
        end)
    end)

    describe("_get_file_path", function()
        local original_cwd
        local original_stdpath

        before_each(function()
            original_cwd = vim.uv.cwd
            original_stdpath = vim.fn.stdpath

            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
            vim.fn.stdpath = original_stdpath
        end)

        it("uses stdpath cache by default", function()
            --- @diagnostic disable-next-line: duplicate-set-field
            vim.fn.stdpath = function(what)
                if what == "cache" then
                    return "/home/user/.cache/nvim"
                end
                return original_stdpath(what)
            end

            local history = ChatHistory:new("session-abc")
            --- @diagnostic disable-next-line: invisible
            local path = history:_get_file_path()

            assert.truthy(path:match("^/home/user/.cache/nvim"))
            assert.truthy(path:match("agentic/sessions"))
            assert.truthy(path:match("session%-abc%.json$"))
        end)

        it("uses custom dir_path when provided", function()
            local history = ChatHistory:new("session-abc", "/custom/cache")
            --- @diagnostic disable-next-line: invisible
            local path = history:_get_file_path()

            assert.truthy(path:match("^/custom/cache"))
            assert.truthy(path:match("agentic/sessions"))
            assert.truthy(path:match("session%-abc%.json$"))
        end)

        it("includes project folder in path", function()
            local history = ChatHistory:new("session-abc", "/cache")
            --- @diagnostic disable-next-line: invisible
            local path = history:_get_file_path()
            --- @diagnostic disable-next-line: invisible
            local project_folder = history:_get_project_folder()

            assert.truthy(path:match(project_folder))
        end)
    end)

    describe("message operations", function()
        describe("add_message", function()
            it("adds message to messages array", function()
                local history = ChatHistory:new("test")

                --- @type agentic.ChatHistory.UserMessage
                local msg = { type = "user", text = "Hello" }

                history:add_message(msg)

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)

            it("preserves message order", function()
                local history = ChatHistory:new("test")

                history:add_message({ type = "user", text = "First" })
                history:add_message({ type = "agent", text = "Second" })

                assert.equal("user", history.messages[1].type)
                assert.equal("agent", history.messages[2].type)
            end)
        end)

        describe("append_agent_text", function()
            it("creates new message when none exists", function()
                local history = ChatHistory:new("test")

                history:append_agent_text("agent", "Hello")

                assert.equal(1, #history.messages)
                assert.equal("agent", history.messages[1].type)
                assert.equal("Hello", history.messages[1].text)
            end)

            it("appends to existing agent message", function()
                local history = ChatHistory:new("test")

                history:append_agent_text("agent", "Hello")
                history:append_agent_text("agent", " World")

                assert.equal(1, #history.messages)
                assert.equal("Hello World", history.messages[1].text)
            end)

            it("creates new message when last is different type", function()
                local history = ChatHistory:new("test")

                history:add_message({ type = "user", text = "Hi" })
                history:append_agent_text("agent", "Hello")

                assert.equal(2, #history.messages)
                assert.equal("agent", history.messages[2].type)
            end)

            it("handles thought type separately", function()
                local history = ChatHistory:new("test")

                history:append_agent_text("agent", "Response")
                history:append_agent_text("thought", "Thinking...")

                assert.equal(2, #history.messages)
                assert.equal("agent", history.messages[1].type)
                assert.equal("thought", history.messages[2].type)
            end)
        end)

        describe("update_tool_call", function()
            it("finds and merges tool_call by ID", function()
                local history = ChatHistory:new("test")

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
                local history = ChatHistory:new("test")

                history:add_message({ type = "user", text = "Hello" })

                -- Should not error
                history:update_tool_call(
                    "non-existent",
                    { status = "completed" }
                )

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)
        end)

        describe("get_messages", function()
            it("returns all messages", function()
                local history = ChatHistory:new("test")

                history:add_message({ type = "user", text = "One" })
                history:add_message({ type = "agent", text = "Two" })

                local messages = history:get_messages()

                assert.equal(2, #messages)
            end)

            it("returns empty array when no messages", function()
                local history = ChatHistory:new("test")

                local messages = history:get_messages()

                assert.equal(0, #messages)
            end)
        end)

        describe("get_title", function()
            it("extracts first user message text", function()
                local history = ChatHistory:new("test")

                history:add_message({
                    type = "user",
                    text = "Fix the bug in auth",
                })
                history:add_message({
                    type = "agent",
                    text = "I'll help with that",
                })

                assert.equal("Fix the bug in auth", history:get_title())
            end)

            it("truncates to 100 characters", function()
                local history = ChatHistory:new("test")

                local long_text = string.rep("a", 150)
                history:add_message({ type = "user", text = long_text })

                local title = history:get_title()

                assert.equal(100, #title)
            end)

            it("returns empty string when no user messages", function()
                local history = ChatHistory:new("test")

                history:add_message({ type = "agent", text = "Hello" })

                assert.equal("", history:get_title())
            end)
        end)

        describe("clear", function()
            it("empties messages array", function()
                local history = ChatHistory:new("test")

                history:add_message({ type = "user", text = "Hello" })

                history:clear()

                assert.equal(0, #history.messages)
            end)
        end)
    end)

    describe("save", function()
        local test_dir
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            test_dir = vim.fn.tempname()
            vim.fn.mkdir(test_dir, "p")

            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
            vim.fn.delete(test_dir, "rf")
        end)

        it("creates JSON file with correct structure", function()
            local history = ChatHistory:new("save-test-123", test_dir)

            history:add_message({ type = "user", text = "Test message" })

            local done = false
            local save_err = nil

            history:save(function(err)
                save_err = err
                done = true
            end)

            -- Wait for async
            vim.wait(1000, function()
                return done
            end)

            assert.is_nil(save_err)

            -- Verify file exists and has correct content
            --- @diagnostic disable-next-line: invisible
            local path = history:_get_file_path()
            local content = vim.fn.readfile(path)
            local json_str = table.concat(content, "\n")
            local parsed = vim.json.decode(json_str)

            assert.equal("save-test-123", parsed.session_id)
            assert.equal("Test message", parsed.title)
            assert.is_not_nil(parsed.timestamp)
            assert.equal(1, #parsed.messages)
        end)

        it("creates directory if not exists", function()
            local history = ChatHistory:new("dir-test", test_dir)

            local done = false
            history:save(function()
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            --- @diagnostic disable-next-line: invisible
            local path = history:_get_file_path()
            local dir = vim.fn.fnamemodify(path, ":h")

            assert.equal(1, vim.fn.isdirectory(dir))
        end)

        it("calls callback on success", function()
            local history = ChatHistory:new("callback-test", test_dir)
            local callback_spy = spy.new(function() end)

            history:save(callback_spy --[[@as function]])

            vim.wait(1000, function()
                return callback_spy.call_count > 0
            end)

            assert.spy(callback_spy).was.called(1)
        end)
    end)

    describe("load", function()
        local test_dir
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            test_dir = vim.fn.tempname()
            vim.fn.mkdir(test_dir, "p")

            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
            vim.fn.delete(test_dir, "rf")
        end)

        it("reads JSON and restores ChatHistory instance", function()
            -- First save a session
            local original = ChatHistory:new("load-test-123", test_dir)
            original:add_message({ type = "user", text = "Saved message" })

            local saved = false
            original:save(function()
                saved = true
            end)

            vim.wait(1000, function()
                return saved
            end)

            -- Now load it
            local loaded = nil
            local load_err = nil
            local loaded_done = false

            ChatHistory.load("load-test-123", test_dir, function(history, err)
                loaded = history
                load_err = err
                loaded_done = true
            end)

            vim.wait(1000, function()
                return loaded_done
            end)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)

            --- @cast loaded agentic.ChatHistory
            assert.equal("load-test-123", loaded.session_id)
            assert.equal(original.timestamp, loaded.timestamp)
            assert.equal(1, #loaded.messages)
            --- @diagnostic disable-next-line: need-check-nil
            assert.equal("Saved message", loaded.messages[1].text)
        end)

        it("returns nil for missing file", function()
            local loaded = nil
            local load_err = nil
            local done = false

            ChatHistory.load("non-existent", test_dir, function(history, err)
                loaded = history
                load_err = err
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.is_nil(loaded)
            assert.is_not_nil(load_err)
        end)

        it("returns error for corrupted JSON", function()
            -- Create a corrupted file
            local temp = ChatHistory:new("corrupted-test", test_dir)
            --- @diagnostic disable-next-line: invisible
            local path = temp:_get_file_path()
            local dir = vim.fn.fnamemodify(path, ":h")
            vim.fn.mkdir(dir, "p")
            vim.fn.writefile({ "not valid json {{{" }, path)

            local loaded = nil
            local load_err = nil
            local done = false

            ChatHistory.load("corrupted-test", test_dir, function(history, err)
                loaded = history
                load_err = err
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.is_nil(loaded)
            assert.is_not_nil(load_err)
        end)
    end)

    describe("list_sessions", function()
        local test_dir
        local original_cwd

        before_each(function()
            original_cwd = vim.uv.cwd
            test_dir = vim.fn.tempname()
            vim.fn.mkdir(test_dir, "p")

            vim.uv.cwd = function()
                return "/test/project"
            end
        end)

        after_each(function()
            vim.uv.cwd = original_cwd
            vim.fn.delete(test_dir, "rf")
        end)

        it("returns empty array when no sessions", function()
            local sessions = nil
            local done = false

            ChatHistory.list_sessions(test_dir, function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.is_table(sessions)
            assert.equal(0, #sessions)
        end)

        it("returns all sessions in project folder", function()
            -- Create two sessions
            local session1 = ChatHistory:new("session-1", test_dir)
            session1:add_message({ type = "user", text = "First session" })

            local session2 = ChatHistory:new("session-2", test_dir)
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

            -- List sessions
            local sessions = nil
            local done = false

            ChatHistory.list_sessions(test_dir, function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(2, #sessions)

            -- Check both sessions are present
            local ids = {}
            for _, s in ipairs(sessions or {}) do
                ids[s.session_id] = true
            end
            assert.is_true(ids["session-1"])
            assert.is_true(ids["session-2"])
        end)
    end)
end)
