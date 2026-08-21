local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Multiple Chat sessions", function()
    local child = Child:new()

    --- @param key integer Session key
    --- @return integer tabpage handle, or -1 when the session is not visible
    local function session_tab(key)
        return child.lua_get(([[
(function()
    local session = require("agentic.session_registry").sessions[%d]
    return session and session.widget:get_visible_tab_id() or -1
end)()
]]):format(key))
    end

    --- @return integer key of the session visible in the current tab, or -1
    local function visible_key()
        return child.lua_get([[
(function()
    local current = vim.api.nvim_get_current_tabpage()
    for key, session in pairs(require("agentic.session_registry").sessions) do
        if session.widget:get_visible_tab_id() == current then
            return key
        end
    end
    return -1
end)()
]])
    end

    --- @return integer
    local function session_count()
        return child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])
    end

    --- @param tabpage integer
    --- @return string[] sorted widget filetypes, hidden floats excluded
    local function widget_filetypes(tabpage)
        return child.lua_get(([[
(function()
    local out = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(%d)) do
        if not vim.api.nvim_win_get_config(winid).hide then
            local ft = vim.bo[vim.api.nvim_win_get_buf(winid)].filetype
            if ft:match("^Agentic") then
                out[#out + 1] = ft
            end
        end
    end
    table.sort(out)
    return out
end)()
]]):format(tabpage))
    end

    --- @param count integer
    local function create_sessions(count)
        child.lua(([[
            for _ = 1, %d do
                require("agentic").new_session({ auto_add_to_context = false })
            end
        ]]):format(count))
        child.flush()
    end

    --- Restore needs a connected client, a `loadSession` capability and an ACP
    --- `session/load`; the transport mock answers none, so `when_ready` never
    --- fires and `SessionRestore` bails before creating anything. Stubbing all
    --- three leaves just the registry bookkeeping this file covers.
    --- `vim.ui.select` is counted so a resurrected conflict prompt shows up.
    --- The capability lands on the class: `ACPClient.__index` is the class table,
    --- so every client in this child inherits it.
    local function stub_restore()
        child.lua([[
            local ACPClient = require("agentic.acp.acp_client")
            ACPClient.when_ready = function(self, on_ready, _on_failure)
                on_ready(self)
            end

            ACPClient.agent_capabilities = {
                loadSession = true,
            }

            _G.load_calls = 0
            _G.subscribe_calls = {}
            local original_subscribe = ACPClient._subscribe
            ACPClient._subscribe = function(self, session_id, handlers)
                _G.subscribe_calls[session_id] =
                    (_G.subscribe_calls[session_id] or 0) + 1
                return original_subscribe(self, session_id, handlers)
            end
            ACPClient.load_session = function(
                self,
                session_id,
                _cwd,
                _servers,
                handlers,
                callback
            )
                _G.load_calls = _G.load_calls + 1
                self:_subscribe(session_id, handlers)
                handlers.on_session_update({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "restored message" },
                })
                callback({}, nil)
            end

            _G.selects = 0
            vim.ui.select = function(items, _, on_choice)
                _G.selects = _G.selects + 1
                on_choice(items[1])
            end
        ]])
    end

    local function stub_new_sessions()
        child.lua([[
            local ACPClient = require("agentic.acp.acp_client")
            ACPClient.when_ready = function(self, on_ready, _on_failure)
                on_ready(self)
            end

            local next_session = 0
            ACPClient.create_session = function(self, handlers, callback)
                next_session = next_session + 1
                local session_id = "new-session-" .. next_session
                self:_subscribe(session_id, handlers)
                callback({ sessionId = session_id }, nil)
            end
        ]])
    end

    before_each(function()
        child.setup()
        child.lua([[
            vim.ui.select = function(items, _, on_choice)
                on_choice(items[1])
            end
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    it("hides the session already visible in the tab", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab = child.api.nvim_get_current_tabpage()
        assert.equal(tab, session_tab(1))

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        assert.equal(2, session_count())
        assert.equal(-1, session_tab(1))
        assert.equal(tab, session_tab(2))
        assert.same({ "AgenticChat", "AgenticInput" }, widget_filetypes(tab))
    end)

    it("moves a session visible in another tab into the current one", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        assert.equal(tab2, session_tab(1))
        assert.same({}, widget_filetypes(tab1))
    end)

    it("toggles a session into the current tab, not out of another", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        assert.equal(tab2, session_tab(1))
        assert.same({}, widget_filetypes(tab1))
    end)

    it("closes only the session visible in the current tab", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")

        -- `close` must not reach `_most_recent`: hiding a widget in another tab,
        -- which the user is not looking at, is never what `close` means.
        child.lua([[ require("agentic").close() ]])
        child.flush()

        assert.equal(tab1, session_tab(1))
        assert.equal(1, session_count())
    end)

    it("creates no session when closing with none open", function()
        child.lua([[ require("agentic").close() ]])
        child.flush()

        assert.equal(0, session_count())
    end)

    it("renders in its own tab when shown from another one", function()
        child.lua(
            [[ require("agentic").open({ auto_add_to_context = false }) ]]
        )
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        -- The REAL content-callback path, not `widget:show`: `FileList`'s
        -- `on_change` calls `ChatWidget:rerender`, and `show` here would exercise
        -- the call `lua/agentic/ui/AGENTS.md` forbids in a content callback. A
        -- session visible in another tab must re-render there, not rebuild itself
        -- in the tab the user sits in.
        child.lua([[
            require("agentic.session_registry").sessions[1].file_list:add(
                vim.fn.fnamemodify("README.md", ":p")
            )
        ]])
        child.flush()

        assert.same(
            { "AgenticChat", "AgenticFiles", "AgenticInput" },
            widget_filetypes(tab1)
        )
        assert.same({}, widget_filetypes(tab2))
        assert.equal(tab1, session_tab(1))
        assert.equal(tab2, child.api.nvim_get_current_tabpage())
    end)

    it("moves the widget rather than duplicating it on add_file", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        -- Every command that opens the widget must go through the eviction choke
        -- point. Showing directly leaves the old tab's windows behind, untracked
        -- in `win_nrs` and impossible to close.
        child.lua([[ require("agentic").add_file() ]])
        child.flush()

        assert.same({}, widget_filetypes(tab1))
        assert.equal(tab2, session_tab(1))
    end)

    it("keeps a hidden session hidden when its file list changes", function()
        child.lua(
            [[ require("agentic").open({ auto_add_to_context = false }) ]]
        )
        child.flush()

        local tab = child.api.nvim_get_current_tabpage()

        child.lua([[
            require("agentic").new_session({ auto_add_to_context = false })
        ]])
        child.flush()

        -- A background session's content callback must never surface its widget:
        -- `show_session` is the only path allowed to. Two widgets in one tab leave
        -- `close` hiding whichever `pairs` reaches first, stranding the other.
        child.lua([[
            require("agentic.session_registry").sessions[1].file_list:add(
                vim.fn.fnamemodify("README.md", ":p")
            )
        ]])
        child.flush()

        assert.equal(-1, session_tab(1))
        assert.same({ "AgenticChat", "AgenticInput" }, widget_filetypes(tab))

        -- Not lost: the panel buffer is written before the callback fires, and
        -- `show` opens every panel with a non-empty buffer.
        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        assert.same(
            { "AgenticChat", "AgenticFiles", "AgenticInput" },
            widget_filetypes(tab)
        )
    end)

    it("keeps the previous session alive when a new one is created", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        assert.equal(2, session_count())
        assert.is_true(child.lua_get([[
            vim.api.nvim_buf_is_valid(
                require("agentic.session_registry").sessions[1].widget.buf_nrs.chat
            )
        ]]))
    end)

    it("slash-new keeps the source when that choice is selected", function()
        stub_new_sessions()
        child.lua([[ require("agentic").open() ]])
        child.flush()
        child.lua([[
            local source = require("agentic.session_registry").sessions[1]
            _G.old_manager = tostring(source)
            _G.old_widget = tostring(source.widget)
            _G.old_chat = source.widget.buf_nrs.chat
            source.chat_history.title = "old title"
            source.chat_history:add_message({
                type = "user",
                text = "old message",
                timestamp = 0,
                provider_name = "test",
            })
            source:_handle_input_submit("/new")
        ]])
        child.flush()

        assert.equal(2, session_count())
        assert.is_true(child.lua_get([[
            (function()
                local source = require("agentic.session_registry").sessions[1]
                local target = require("agentic.session_registry").sessions[2]
                return source ~= nil
                    and target ~= nil
                    and tostring(target) ~= _G.old_manager
                    and tostring(target.widget) ~= _G.old_widget
                    and target.widget.buf_nrs.chat ~= _G.old_chat
                    and target.chat_history.title == ""
                    and #target.chat_history.messages == 0
                    and vim.api.nvim_buf_is_valid(_G.old_chat)
            end)()
        ]]))
    end)

    it("slash-new destroys the source only when selected", function()
        stub_new_sessions()
        child.lua([[ require("agentic").open() ]])
        child.flush()
        child.lua([[
            local source = require("agentic.session_registry").sessions[1]
            _G.old_chat = source.widget.buf_nrs.chat
            vim.ui.select = function(items, _, on_choice)
                on_choice(items[2])
            end
            source:_handle_input_submit("/new")
        ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(2, visible_key())
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[1] == nil
                and not vim.api.nvim_buf_is_valid(_G.old_chat)
        ]]))
    end)

    it("keeps a session registered after its tab is closed", function()
        child.cmd("tabnew")
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.cmd("tabclose")
        child.flush()

        assert.equal(1, session_count())
        assert.equal(-1, session_tab(1))
    end)

    it("slash-new inherits the resized width of its source", function()
        stub_new_sessions()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.lua([[
            local session = require("agentic.session_registry").sessions[1]
            require("agentic.utils.buf_helpers")
                .win_set_width(session.widget.win_nrs.chat, 50)
        ]])

        child.lua([[
            require("agentic.session_registry").sessions[1]
                :_handle_input_submit("/new")
        ]])
        child.flush()

        assert.equal(2, session_count())
        assert.equal(
            50,
            child.lua_get([[
                vim.api.nvim_win_get_width(
                    require("agentic.session_registry").sessions[2].widget.win_nrs.chat
                )
            ]])
        )
    end)

    it("inherits the width of the session shown before it", function()
        -- TWO donors with DIFFERENT widths. With one, recency order and
        -- ascending-key order coincide, so a donor scan falling back to the
        -- lowest key still looks right.
        child.lua([[ require("agentic").open() ]])
        child.flush()

        -- Session 1 stays at the configured width; session 2 replaces it and is
        -- the one resized.
        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        child.lua([[
            local session = require("agentic.session_registry").sessions[2]
            require("agentic.utils.buf_helpers")
                .win_set_width(session.widget.win_nrs.chat, 50)
        ]])

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        assert.equal(
            50,
            child.lua_get([[
                vim.api.nvim_win_get_width(
                    require("agentic.session_registry").sessions[3].widget.win_nrs.chat
                )
            ]])
        )
    end)

    it("rotates nothing from a tab with no visible session", function()
        -- Same tab-locality rule as `Agentic.close`: a widget the user is not
        -- looking at must not be rebuilt in the current tabpage.
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        child.lua([[ require("agentic").rotate_layout() ]])
        child.flush()

        assert.equal(tab1, session_tab(1))
        assert.same({}, widget_filetypes(tab2))
        assert.equal(1, session_count())
    end)

    it("shows one session per tab simultaneously", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        assert.equal(tab1, session_tab(1))
        assert.equal(tab2, session_tab(2))
    end)

    it("returns to the starting session after next then prev", function()
        -- Three is the minimum that detects cycling over a mutable order: with
        -- two, `next` then `prev` lands back by accident.
        create_sessions(3)
        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        child.lua([[ require("agentic").next_session() ]])
        child.flush()
        assert.equal(2, visible_key())

        child.lua([[ require("agentic").prev_session() ]])
        child.flush()
        assert.equal(1, visible_key())
    end)

    it("focuses the target input when cycling sessions", function()
        create_sessions(2)

        child.lua([[
            local session = require("agentic.session_registry").visible_here()
            _G.editor_win = session.widget:find_first_non_widget_window()
            vim.api.nvim_set_current_win(_G.editor_win)
            vim.cmd("stopinsert")
        ]])

        child.lua([[ require("agentic").next_session() ]])
        child.flush()

        assert.equal(
            child.lua_get([[
                require("agentic.session_registry").sessions[1].widget.buf_nrs.input
            ]]),
            child.api.nvim_get_current_buf()
        )
        assert.equal("i", child.fn.mode())
    end)

    it("wraps around after cycling through every session", function()
        create_sessions(3)
        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        --- @type integer[]
        local seen = {}

        for _ = 1, 3 do
            child.lua([[ require("agentic").next_session() ]])
            child.flush()
            seen[#seen + 1] = visible_key()
        end

        assert.same({ 2, 3, 1 }, seen)
    end)

    it("opens the session chosen in the picker", function()
        create_sessions(2)
        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        child.lua([[
            _G.labels = {}
            vim.ui.select = function(items, opts, on_choice)
                for _, item in ipairs(items) do
                    _G.labels[#_G.labels + 1] = opts.format_item(item)
                end
                for _, item in ipairs(items) do
                    if item.session_key == 2 then
                        on_choice(item)
                        return
                    end
                end
            end
            require("agentic").select_session()
        ]])
        child.flush()

        assert.equal(2, visible_key())

        -- `list()` puts this tab's visible session first; only it gets the marker.
        local labels = child.lua_get([[_G.labels]])
        assert.equal(2, #labels)
        assert.truthy(labels[1]:match("^● "))
        assert.truthy(labels[2]:match("^  "))
    end)

    it("destroys the resolved session and keeps the others", function()
        create_sessions(2)
        child.lua([[ require("agentic.session_registry").show_session(1) ]])
        child.flush()

        child.lua([[ require("agentic").destroy_session() ]])
        child.flush()

        assert.equal(1, session_count())
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[1] == nil
        ]]))
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[2] ~= nil
        ]]))
    end)

    it("destroys the named session, not the visible one", function()
        create_sessions(2)
        child.lua([[ require("agentic.session_registry").show_session(2) ]])
        child.flush()

        child.lua([[ require("agentic").destroy_session({ session = 1 }) ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(2, visible_key())
    end)

    it("creates no session when destroying with none open", function()
        child.lua([[ require("agentic").destroy_session() ]])
        child.flush()

        assert.equal(0, session_count())
    end)

    it("creates one restore target without a placeholder", function()
        stub_restore()

        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(1, visible_key())
        assert.equal(1, child.lua_get([[_G.load_calls]]))
        assert.equal(0, child.lua_get([[_G.selects]]))
    end)

    it("inherits the resized width of the session it restores over", function()
        stub_restore()
        child.lua(
            [[ require("agentic").open({ auto_add_to_context = false }) ]]
        )
        child.flush()

        child.lua([[
            local session = require("agentic.session_registry").sessions[1]
            require("agentic.utils.buf_helpers")
                .win_set_width(session.widget.win_nrs.chat, 50)
            _G.old_manager = tostring(session)
            _G.old_widget = tostring(session.widget)
            _G.old_chat = session.widget.buf_nrs.chat
            session.chat_history.title = "source title"
            session.chat_history:add_message({
                type = "user",
                text = "source-only message",
                timestamp = 0,
                provider_name = "test",
            })
            session.source_only_property = "must not transfer"
        ]])

        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(2, session_count())
        assert.equal(1, child.lua_get([[_G.load_calls]]))
        assert.equal(1, child.lua_get([[_G.selects]]))
        assert.is_true(child.lua_get([[
            (function()
                local source = require("agentic.session_registry").sessions[1]
                local target = require("agentic.session_registry").sessions[2]
                return source ~= nil
                    and target ~= nil
                    and tostring(target) ~= _G.old_manager
                    and tostring(target.widget) ~= _G.old_widget
                    and target.widget.buf_nrs.chat ~= _G.old_chat
                    and vim.api.nvim_buf_is_valid(_G.old_chat)
                    and target.chat_history.title == ""
                    and target.source_only_property == nil
                    and #target.chat_history.messages == 1
            end)()
        ]]))
        assert.equal(
            "restored message",
            child.lua_get([[
                require("agentic.session_registry").sessions[2]
                    .chat_history.messages[1].text
            ]])
        )
        assert.equal(
            50,
            child.lua_get([[
                vim.api.nvim_win_get_width(
                    require("agentic.session_registry").sessions[2].widget.win_nrs.chat
                )
            ]])
        )
    end)

    it("destroys the source only when restore selects that choice", function()
        stub_restore()
        child.lua(
            [[ require("agentic").open({ auto_add_to_context = false }) ]]
        )
        child.flush()
        child.lua([[
            local source = require("agentic.session_registry").sessions[1]
            _G.old_chat = source.widget.buf_nrs.chat
            vim.ui.select = function(items, _, on_choice)
                _G.selects = _G.selects + 1
                on_choice(items[2])
            end
        ]])

        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(2, visible_key())
        assert.equal(1, child.lua_get([[_G.selects]]))
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[1] == nil
                and not vim.api.nvim_buf_is_valid(_G.old_chat)
        ]]))
    end)

    it("shows an existing loaded target without loading twice", function()
        stub_restore()
        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()
        child.lua([[
            local target = require("agentic.session_registry").sessions[1]
            _G.loaded_manager = tostring(target)
            _G.loaded_subscriber = tostring(target.agent.subscribers["sid-1"])
        ]])
        child.lua([[
            vim.ui.select = function(items, _, on_choice)
                _G.selects = _G.selects + 1
                on_choice(items[1])
            end
            require("agentic").new_session()
        ]])
        child.flush()
        assert.equal(2, session_count())
        child.lua([[
            local source = require("agentic.session_registry").sessions[2]
            _G.source_chat = source.widget.buf_nrs.chat
        ]])

        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(2, session_count())
        assert.equal(1, visible_key())
        assert.equal(1, child.lua_get([[_G.load_calls]]))
        assert.equal(1, child.lua_get([=[_G.subscribe_calls["sid-1"]]=]))
        assert.is_true(child.lua_get([[
            (function()
                local target = require("agentic.session_registry").sessions[1]
                return tostring(target) == _G.loaded_manager
                    and tostring(target.agent.subscribers["sid-1"])
                        == _G.loaded_subscriber
                    and require("agentic.session_registry").sessions[2] ~= nil
                    and vim.api.nvim_buf_is_valid(_G.source_chat)
            end)()
        ]]))
    end)

    it("leaves a single session in place when cycling", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.lua([[ require("agentic").next_session() ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(1, visible_key())
    end)
end)
