local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionNavigation", function()
    local SessionNavigation
    local sessions
    local current_session
    local registry_mock
    local ui_select_stub

    local original_registry = package.loaded["agentic.session_registry"]
    local original_navigation = package.loaded["agentic.session_navigation"]

    --- @param key integer
    --- @param title string|nil
    --- @param visible_tab integer|nil
    --- @return table session
    local function create_session(key, title, visible_tab)
        return {
            session_key = key,
            chat_history = { title = title or "" },
            agent = { provider_config = { name = "TestProvider" } },
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
        ui_select_stub:revert()
        package.loaded["agentic.session_registry"] = original_registry
        package.loaded["agentic.session_navigation"] = original_navigation
    end)

    it("lists live sessions and opens the selected one", function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        local first = create_session(1, "First", current_tab)
        local second = create_session(2, "", nil)
        sessions = { first, second }
        ui_select_stub:invokes(function(items, opts, on_choice)
            assert.equal(sessions, items)
            assert.equal("First (current tab)", opts.format_item(first))
            assert.equal("TestProvider", opts.format_item(second))
            on_choice(second)
        end)

        SessionNavigation.select()

        assert.spy(registry_mock.show_session).was.called_with(2)
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
