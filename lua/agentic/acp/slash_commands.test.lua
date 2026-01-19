local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local States = require("agentic.states")

describe("agentic.acp.SlashCommands", function()
    local SlashCommands = require("agentic.acp.slash_commands")

    --- @type integer
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        SlashCommands.setup_completion(bufnr)
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("setCommands", function()
        it(
            "sets commands from ACP provider and automatically adds /new",
            function()
                --- @type agentic.acp.AvailableCommand[]
                local commands_mock = {
                    { name = "plan", description = "Create a plan" },
                    { name = "review", description = "Review code" },
                }

                SlashCommands.setCommands(bufnr, commands_mock)

                local commands = States.getSlashCommands()

                -- Verify total count includes /new
                assert.equal(3, #commands)

                -- Verify provided commands are set correctly
                assert.equal("plan", commands[1].word)
                assert.equal("Create a plan", commands[1].menu)
                assert.equal("review", commands[2].word)
                assert.equal("Review code", commands[2].menu)

                -- Verify /new was automatically added at the end
                assert.equal("new", commands[3].word)
                assert.equal("Start a new session", commands[3].menu)
            end
        )

        it("does not duplicate /new command if already provided", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "new", description = "Custom new description" },
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands)

            local new_count = 0
            for _, cmd in ipairs(commands) do
                if cmd.word == "new" then
                    new_count = new_count + 1
                    assert.equal("Custom new description", cmd.menu)
                end
            end
            assert.equal(1, new_count)
        end)

        it("filters out commands with spaces in name", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "has space", description = "Invalid command" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- valid + /new
            for _, cmd in ipairs(commands) do
                assert.is_false(cmd.word:match("%s") ~= nil)
            end
        end)

        it("filters out clear command", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "clear", description = "Clear session" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- plan + /new
            for _, cmd in ipairs(commands) do
                assert.is_not.equal("clear", cmd.word)
            end
        end)

        it("skips commands with missing name or description", function()
            --- @type table[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "no-desc" }, -- Missing description
                { description = "No name" }, -- Missing name
            }

            ---@diagnostic disable-next-line: param-type-mismatch
            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- valid + /new
        end)

        it("sets case-insensitive completion", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            for _, cmd in ipairs(commands) do
                assert.equal(1, cmd.icase)
            end
        end)
    end)

    describe("completion setup", function()
        it("configures buffer with correct completeopt", function()
            local completeopt = vim.bo[bufnr].completeopt
            assert.equal("menu,menuone,noinsert,popup,fuzzy", completeopt)
        end)

        it("adds '-' to iskeyword", function()
            local iskeyword = vim.bo[bufnr].iskeyword
            assert.is_true(iskeyword:match(",-") ~= nil)
        end)

        it("sets completefunc - must not use () - vim fallback", function()
            local completefunc = vim.bo[bufnr].completefunc
            assert.equal(
                "v:lua.require'agentic.acp.slash_commands'.complete_func",
                completefunc
            )
        end)
    end)

    describe("complete_func", function()
        it("returns commands on findstart=0", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local result = SlashCommands.complete_func(0, "pl")
            assert.is_table(result)
            assert.is_true(#result > 0)
        end)

        it("returns empty table when no instance for buffer", function()
            local new_bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_set_current_buf(new_bufnr)

            local result = SlashCommands.complete_func(0, "test")

            assert.is_table(result)
            assert.equal(0, #result)

            if vim.api.nvim_buf_is_valid(new_bufnr) then
                vim.api.nvim_buf_delete(new_bufnr, { force = true })
            end
        end)
    end)

    describe("TextChangedI autocommand", function()
        it("triggers feedkeys when typing / at start of line", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local feedkeys_spy = spy.on(vim.api, "nvim_feedkeys")

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p" })
            vim.api.nvim_win_set_cursor(0, { 1, 2 })

            vim.cmd("startinsert")
            vim.cmd("doautocmd TextChangedI")

            local completion_keys =
                vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true)
            assert
                .spy(feedkeys_spy).was
                .called_with(completion_keys, "n", false)

            -- Cleanup
            feedkeys_spy:revert()
        end)

        it("does not trigger completion when commands list is empty", function()
            local feedkeys_spy = spy.on(vim.api, "nvim_feedkeys")

            vim.cmd("startinsert")

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p" })
            vim.api.nvim_win_set_cursor(0, { 1, 2 })

            vim.cmd("doautocmd TextChangedI")

            assert.spy(feedkeys_spy).was.called(0)

            feedkeys_spy:revert()
        end)

        it("does not trigger completion when not at start of line", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands)

            local feedkeys_spy = spy.on(vim.api, "nvim_feedkeys")

            vim.cmd("startinsert")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "some /p" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            vim.cmd("doautocmd TextChangedI")

            assert.spy(feedkeys_spy).was.called(0)

            feedkeys_spy:revert()
        end)

        it("does not trigger completion when line contains space", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands)

            local feedkeys_spy = spy.on(vim.api, "nvim_feedkeys")

            vim.cmd("startinsert")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p " })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            vim.cmd("doautocmd TextChangedI")

            assert.spy(feedkeys_spy).was.called(0)

            feedkeys_spy:revert()
        end)

        it("does not trigger completion when not on first row", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands)

            local feedkeys_spy = spy.on(vim.api, "nvim_feedkeys")

            vim.cmd("startinsert")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "/p" })
            vim.api.nvim_win_set_cursor(0, { 2, 2 })

            vim.cmd("doautocmd TextChangedI")

            assert.spy(feedkeys_spy).was.called(0)

            feedkeys_spy:revert()
        end)
    end)

    describe("instance management", function()
        it("allows independent commands per buffer instance", function()
            local bufnr2 = vim.api.nvim_create_buf(false, true)
            SlashCommands.setup_completion(bufnr2)

            --- @type agentic.acp.AvailableCommand[]
            local commands1 = {
                { name = "plan", description = "Create a plan" },
            }

            --- @type agentic.acp.AvailableCommand[]
            local commands2 = {
                { name = "review", description = "Review code" },
            }

            SlashCommands.setCommands(bufnr, commands1)
            SlashCommands.setCommands(bufnr2, commands2)

            local commands_buf1 = States.getSlashCommands()
            vim.api.nvim_set_current_buf(bufnr2)
            local commands_buf2 = States.getSlashCommands()

            assert.equal(2, #commands_buf1) -- plan + /new
            assert.equal(2, #commands_buf2) -- review + /new
            assert.equal("plan", commands_buf1[1].word)
            assert.equal("review", commands_buf2[1].word)

            if vim.api.nvim_buf_is_valid(bufnr2) then
                vim.api.nvim_buf_delete(bufnr2, { force = true })
            end
        end)
    end)
end)
