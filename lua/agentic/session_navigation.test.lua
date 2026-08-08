local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Logger = require("agentic.utils.logger")

describe("agentic.SessionNavigation", function()
    local SessionNavigation
    local sessions
    local current_session
    local logger_notify_stub
    local registry_mock
    local ui_select_stub

    local original_registry = package.loaded["agentic.session_registry"]
    local original_navigation = package.loaded["agentic.session_navigation"]

    --- @param key integer
    --- @param title string|nil
    --- @param visible_tab integer|nil
    --- @param agent table|nil Defaults to a `TestProvider` agent
    --- @return table session
    local function create_session(key, title, visible_tab, agent)
        return {
            session_key = key,
            chat_history = { title = title or "" },
            agent = agent or { provider_config = { name = "TestProvider" } },
            widget = {
                get_visible_tab_id = function()
                    return visible_tab
                end,
            },
        }
    end

    before_each(function()
        sessions = {}
        current_session = nil
        logger_notify_stub = spy.stub(Logger, "notify")
        registry_mock = {
            list = spy.new(function()
                return sessions
            end),
            current = spy.new(function()
                return current_session
            end),
            show_session = spy.new(function() end),
        }

        package.loaded["agentic.session_registry"] = registry_mock
        package.loaded["agentic.session_navigation"] = nil
        SessionNavigation = require("agentic.session_navigation")
        ui_select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        logger_notify_stub:revert()
        ui_select_stub:revert()
        package.loaded["agentic.session_registry"] = original_registry
        package.loaded["agentic.session_navigation"] = original_navigation
    end)

    it("reports when no sessions are available", function()
        SessionNavigation.select()

        assert.spy(logger_notify_stub).was.called(1)
        assert.spy(logger_notify_stub).was.called_with("No sessions available")
        assert.spy(ui_select_stub).was.called(0)
    end)

    it("lists live sessions and opens the selected one", function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        local first = create_session(1, "First", current_tab)
        local second = create_session(2, "", nil)
        sessions = { first, second }
        ui_select_stub:invokes(function(items, opts, on_choice)
            assert.equal(sessions, items)
            assert.equal(
                "● First [TestProvider] (1)",
                opts.format_item(first)
            )
            assert.equal(
                "  Untitled [TestProvider] (2)",
                opts.format_item(second)
            )
            on_choice(second)
        end)

        SessionNavigation.select()

        assert.spy(registry_mock.show_session).was.called_with(2)
    end)

    it("distinguishes untitled sessions on the same provider", function()
        local first = create_session(1, "", nil)
        local second = create_session(2, "", nil)
        sessions = { first, second }

        --- @type string|nil, string|nil
        local first_label, second_label
        ui_select_stub:invokes(function(_, opts, on_choice)
            first_label = opts.format_item(first)
            second_label = opts.format_item(second)
            on_choice(nil)
        end)

        SessionNavigation.select()

        assert.is_not.equal(first_label, second_label)
        assert.truthy(first_label and first_label:find("TestProvider", 1, true))
        assert.truthy(first_label and first_label:find("1", 1, true))
        assert.truthy(second_label and second_label:find("2", 1, true))
    end)

    it("appends the session key to a titled session too", function()
        local titled = create_session(7, "My Chat", nil)
        sessions = { titled, create_session(8, "", nil) }

        --- @type string|nil
        local label
        ui_select_stub:invokes(function(_, opts, on_choice)
            label = opts.format_item(titled)
            on_choice(nil)
        end)

        SessionNavigation.select()

        assert.equal("  My Chat [TestProvider] (7)", label)
    end)

    it("shows the provider next to the title of a titled session", function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        local titled = create_session(1, "My Chat", current_tab, {
            provider_config = { name = "claude-acp" },
        })
        sessions = { titled }

        --- @type string|nil
        local label
        ui_select_stub:invokes(function(_, opts, on_choice)
            label = opts.format_item(titled)
            on_choice(nil)
        end)

        SessionNavigation.select()

        assert.equal("● My Chat [claude-acp] (1)", label)
    end)

    it("shows the provider of an untitled session", function()
        local untitled = create_session(2, "", nil, {
            provider_config = { name = "gemini-acp" },
        })
        sessions = { untitled }

        --- @type string|nil
        local label
        ui_select_stub:invokes(function(_, opts, on_choice)
            label = opts.format_item(untitled)
            on_choice(nil)
        end)

        SessionNavigation.select()

        assert.equal("  Untitled [gemini-acp] (2)", label)
    end)

    it("labels a session whose agent has no provider config", function()
        local orphan = create_session(4, "", nil, {})
        sessions = { orphan }

        --- @type string|nil
        local label
        ui_select_stub:invokes(function(_, opts, on_choice)
            label = opts.format_item(orphan)
            on_choice(nil)
        end)

        assert.has_no_errors(function()
            SessionNavigation.select()
        end)

        assert.equal("  Untitled (4)", label)
    end)

    it("does nothing when session selection is cancelled", function()
        sessions = { create_session(1) }
        ui_select_stub:invokes(function(_, _, on_choice)
            on_choice(nil)
        end)

        SessionNavigation.select()

        assert.spy(registry_mock.show_session).was.called(0)
    end)

    it("opens the next session in ascending key order", function()
        local first = create_session(1)
        sessions = { create_session(3), first, create_session(2) }
        current_session = first

        SessionNavigation.next()

        assert.spy(registry_mock.show_session).was.called_with(2)
    end)

    it("opens the previous session and wraps at the start", function()
        local first = create_session(1)
        sessions = { create_session(2), first, create_session(3) }
        current_session = first

        SessionNavigation.previous()

        assert.spy(registry_mock.show_session).was.called_with(3)
    end)

    it("opens the previous session in descending key order", function()
        local third = create_session(3)
        sessions = { create_session(1), third, create_session(2) }
        current_session = third

        SessionNavigation.previous()

        assert.spy(registry_mock.show_session).was.called_with(2)
    end)

    it("wraps next at the highest session key", function()
        local third = create_session(3)
        sessions = { create_session(2), third, create_session(1) }
        current_session = third

        SessionNavigation.next()

        assert.spy(registry_mock.show_session).was.called_with(1)
    end)

    it("does nothing with fewer than two sessions", function()
        current_session = create_session(1)
        sessions = { current_session }

        SessionNavigation.next()

        assert.spy(registry_mock.show_session).was.called(0)
    end)

    it("does nothing without a current session", function()
        sessions = { create_session(1), create_session(2) }

        SessionNavigation.next()

        assert.spy(registry_mock.show_session).was.called(0)
    end)
end)
