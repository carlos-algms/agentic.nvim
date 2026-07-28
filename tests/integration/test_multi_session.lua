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

    --- Restore needs a connected client, an announced `loadSession` capability and
    --- an ACP `session/load`; the transport mock answers none of them, so
    --- `when_ready` would never fire and `SessionRestore` would bail before
    --- creating anything. Stubbing all three leaves exactly the registry
    --- bookkeeping this file covers. `vim.ui.select` is counted so a resurrected
    --- conflict prompt shows up as a call.
    --- The capability lands on the class, not an instance: `ACPClient.__index` is
    --- the class table, so every client created in this child inherits it.
    local function stub_restore()
        child.lua([[
            require("agentic.acp.acp_client").when_ready = function(_self, cb)
                cb()
            end

            require("agentic.acp.acp_client").agent_capabilities = {
                loadSession = true,
            }

            local SessionManager = require("agentic.session_manager")
            SessionManager.load_acp_session = function(self, session_id, title)
                self.session_id = session_id
                self.chat_history.title = title or ""
            end

            _G.selects = 0
            vim.ui.select = function()
                _G.selects = _G.selects + 1
            end
        ]])
    end

    before_each(function()
        child.setup()
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

        -- `close` must not reach `_most_recent`: hiding a widget the user is not
        -- looking at, in another tab, is never what `close` here means.
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
        child.lua([[ require("agentic").open() ]])
        child.flush()

        local tab1 = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        local tab2 = child.api.nvim_get_current_tabpage()

        -- What `SessionManager`'s content callbacks do while the user sits in
        -- another tab: a background session adding a file must not rebuild its
        -- widget here and abandon the copy in its own tab.
        child.lua([[
            require("agentic.session_registry").sessions[1].widget:show({
                focus_prompt = false,
            })
        ]])
        child.flush()

        assert.same({ "AgenticChat", "AgenticInput" }, widget_filetypes(tab1))
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
        -- in `win_nrs` and therefore impossible to close.
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
        -- `show_session` is the only path allowed to make one visible, and two
        -- widgets in one tab leave `close` hiding whichever `pairs` reaches first
        -- and stranding the other.
        child.lua([[
            require("agentic.session_registry").sessions[1].file_list:add(
                vim.fn.fnamemodify("README.md", ":p")
            )
        ]])
        child.flush()

        assert.equal(-1, session_tab(1))
        assert.same({ "AgenticChat", "AgenticInput" }, widget_filetypes(tab))

        -- Not lost: the panel buffer is written before the callback fires, and
        -- `show` opens every panel whose buffer is non-empty.
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

    it("keeps a session registered after its tab is closed", function()
        child.cmd("tabnew")
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.cmd("tabclose")
        child.flush()

        assert.equal(1, session_count())
        assert.equal(-1, session_tab(1))
    end)

    it("inherits the resized width of the session it replaces", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.lua([[
            local session = require("agentic.session_registry").sessions[1]
            require("agentic.utils.buf_helpers")
                .win_set_width(session.widget.win_nrs.chat, 50)
        ]])

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

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
        -- TWO donors carrying DIFFERENT widths. With one donor, recency order
        -- and ascending-key order coincide and a donor scan that falls back to
        -- the lowest key still looks right.
        child.lua([[ require("agentic").open() ]])
        child.flush()

        -- Session 1 is hidden at the configured width; session 2 replaces it and
        -- is the one the user resizes.
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
        -- looking at must not be torn down and rebuilt in the current tabpage.
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
        -- Three sessions is the minimum that detects cycling over a mutable
        -- order: with two, `next` then `prev` lands back by accident.
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

        -- `list()` puts the session visible in this tab first, and only it
        -- carries the marker
        local labels = child.lua_get([[_G.labels]])
        assert.equal(2, #labels)
        assert.truthy(labels[1]:match("%(current tab%)$"))
        assert.is_nil(labels[2]:match("%(current tab%)$"))
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

    it("destroys the empty session it was resolved into", function()
        stub_restore()

        -- `Agentic.restore_session_by_id` resolves through the registry, which
        -- creates a session just to reach `.agent`. Restoring into a brand new
        -- one would otherwise strand that empty session forever.
        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(2, visible_key())
        assert.equal(0, child.lua_get([[_G.selects]]))
    end)

    -- `_inherited_size` reads the donor at `show` time, and `ChatWidget:destroy`
    -- never captures a size. Destroying the resolved session before the restored
    -- one is shown therefore drops the only donor in the common single-session
    -- case, and a user who resized the sidebar gets the configured default back
    -- after every restore.
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
        ]])

        child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(
            50,
            child.lua_get([[
                vim.api.nvim_win_get_width(
                    require("agentic.session_registry").sessions[2].widget.win_nrs.chat
                )
            ]])
        )
    end)

    -- Five inputs, not one: an implementation testing only messages passes a
    -- messages case while silently destroying staged files, selections,
    -- diagnostics, or a half-typed prompt — user work that only explicit intent
    -- may discard. A typed paragraph is the one input that cannot be re-added
    -- with a single keystroke.
    for _, seed in ipairs({
        {
            name = "messages",
            lua = [[
                session.chat_history:add_message({
                    type = "user",
                    text = "keep me",
                    timestamp = 0,
                    provider_name = "test",
                })
            ]],
        },
        {
            name = "files",
            lua = [[
                session.file_list:add(vim.fn.fnamemodify("README.md", ":p"))
            ]],
        },
        {
            name = "code selections",
            lua = [[
                session.code_selection:add({
                    lines = { "local x = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "init.lua",
                    file_type = "lua",
                })
            ]],
        },
        {
            name = "diagnostics",
            lua = [[
                session.diagnostics_list:add_many({
                    {
                        bufnr = vim.api.nvim_get_current_buf(),
                        lnum = 0,
                        col = 0,
                        severity = vim.diagnostic.severity.ERROR,
                        message = "boom",
                        file_path = "init.lua",
                    },
                })
            ]],
        },
        {
            name = "unsent input text",
            lua = [[
                vim.api.nvim_buf_set_lines(
                    session.widget.buf_nrs.input,
                    0,
                    -1,
                    false,
                    { "", "a paragraph the user is still typing", "" }
                )
            ]],
        },
    }) do
        it("keeps a session holding only " .. seed.name, function()
            stub_restore()
            child.lua([[ require("agentic").open() ]])
            child.flush()

            child.lua(([[
                local session = require("agentic.session_registry").sessions[1]
                %s
            ]]):format(seed.lua))
            child.flush()

            child.lua([[ require("agentic").restore_session_by_id("sid-1") ]])
            child.flush()

            assert.equal(2, session_count())
            assert.equal(2, visible_key())
            assert.equal(0, child.lua_get([[_G.selects]]))
        end)
    end

    it("leaves a single session in place when cycling", function()
        child.lua([[ require("agentic").open() ]])
        child.flush()

        child.lua([[ require("agentic").next_session() ]])
        child.flush()

        assert.equal(1, session_count())
        assert.equal(1, visible_key())
    end)
end)
