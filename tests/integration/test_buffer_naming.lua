local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Buffer Naming", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    --- Creates a session through the session-keyed registry and shows it
    --- @return integer session_key
    local function open_session()
        return child.lua_get([[
(function()
    local session = require("agentic.session_registry").create()
    session.widget:show({ focus_prompt = false })
    return session.session_key
end)()
]])
    end

    --- Gets the buffer basename of a panel owned by the given session
    --- @param session_key integer
    --- @param panel string Panel name (chat, input, code, files, todos)
    --- @return string basename
    local function get_panel_basename(session_key, panel)
        local bufname = child.lua_get(string.format(
            [[
(function()
    local session = require("agentic.session_registry").sessions[%d]
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.%s)
end)()
]],
            session_key,
            panel
        ))
        return child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], bufname)
        )
    end

    --- Re-renders one panel's header, which is what rewrites the buffer name
    --- @param session_key integer
    --- @param panel string
    local function render_header(session_key, panel)
        child.lua(string.format(
            [[
local session = require("agentic.session_registry").sessions[%d]
session.widget:render_header("%s")
]],
            session_key,
            panel
        ))
        child.flush()
    end

    --- Opens the widget through the public API, the path a user actually takes
    --- @return integer tab_page_id
    local function open_via_public_api()
        return child.lua_get([[
(function()
    require("agentic").open({ auto_add_to_context = false })
    return vim.api.nvim_get_current_tabpage()
end)()
]])
    end

    --- Gets the chat buffer basename of the session owning the given tab page
    --- @param tab_page_id integer
    --- @return string basename
    local function get_chat_basename_for_tab(tab_page_id)
        return child.lua_get(string.format(
            [[
(function()
    local session = require("agentic.session_registry").sessions[%d]
    return vim.fn.fnamemodify(
        vim.api.nvim_buf_get_name(session.widget.buf_nrs.chat),
        ":t"
    )
end)()
]],
            tab_page_id
        ))
    end

    it("keeps names unique when opened through the public API", function()
        local tab1 = open_via_public_api()
        child.flush()

        child.cmd("tabnew")
        local tab2 = open_via_public_api()
        child.flush()

        local basename1 = get_chat_basename_for_tab(tab1)
        local basename2 = get_chat_basename_for_tab(tab2)

        -- Opening the second session must not demote the first one's buffer
        assert.is_nil(basename1:match("%-old%-"))
        assert.is_not.equal(basename1, basename2)
    end)

    it("buffer names mirror header titles", function()
        local key = open_session()
        child.flush()

        local basename = get_panel_basename(key, "chat")

        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it("adds a session suffix for multiple sessions", function()
        local key1 = open_session()
        child.flush()

        child.cmd("tabnew")
        local key2 = open_session()
        child.flush()

        render_header(key1, "input")

        local basename1 = get_panel_basename(key1, "input")
        local basename2 = get_panel_basename(key2, "input")

        assert.is_true(vim.startswith(basename1, "󰦨 Prompt"))
        assert.is_true(vim.startswith(basename2, "󰦨 Prompt"))

        -- Each session carries its own key, not a tabpage handle
        assert.is_not_nil(basename1:match("%(1%)$"))
        assert.is_not_nil(basename2:match("%(2%)$"))
    end)

    it("does not demote the first session's buffers", function()
        local key1 = open_session()
        child.flush()

        child.cmd("tabnew")
        open_session()
        child.flush()

        local basename = get_panel_basename(key1, "chat")

        assert.is_nil(basename:match("%-old%-"))
    end)

    it("returns to the bare name once the other session is gone", function()
        local key1 = open_session()
        child.flush()

        child.cmd("tabnew")
        local key2 = open_session()
        child.flush()

        render_header(key1, "chat")
        assert.is_not_nil(get_panel_basename(key1, "chat"):match("%(1%)$"))

        child.lua(
            string.format(
                [[ require("agentic.session_registry").destroy(%d) ]],
                key2
            )
        )
        render_header(key1, "chat")

        assert.equal("󰻞 Agentic Chat", get_panel_basename(key1, "chat"))
    end)

    it("prevents buffer name collision errors", function()
        for _ = 1, 5 do
            open_session()
            child.flush()
            child.cmd("tabnew")
        end

        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])

        assert.equal(5, session_count)
    end)

    it("uses custom buffer_name from windows config when set", function()
        child.lua([[
            require("agentic").setup({ windows = { chat = { buffer_name = "My Chat" } } })
        ]])
        local key = open_session()
        child.flush()

        local basename = get_panel_basename(key, "chat")
        assert.is_true(vim.startswith(basename, "My Chat"))
    end)

    it("uses buffer_name function to derive name from header parts", function()
        child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function(parts)
                            return "Custom: " .. parts.title
                        end,
                    },
                },
            })
        ]])
        local key = open_session()
        child.flush()

        local basename = get_panel_basename(key, "chat")
        assert.is_true(vim.startswith(basename, "Custom: 󰻞 Agentic Chat"))
    end)

    it("falls back to header title when buffer_name not set", function()
        child.lua([[ require("agentic").setup({}) ]])
        local key = open_session()
        child.flush()

        local basename = get_panel_basename(key, "chat")
        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it("falls back to header title when buffer_name function throws", function()
        child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function()
                            error("intentional error")
                        end,
                    },
                },
            })
        ]])
        local key = open_session()
        child.flush()

        local basename = get_panel_basename(key, "chat")
        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it(
        "falls back to header title when buffer_name function returns nil",
        function()
            child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function()
                            return nil
                        end,
                    },
                },
            })
        ]])
            local key = open_session()
            child.flush()

            local basename = get_panel_basename(key, "chat")
            assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
        end
    )

    it(
        "assigns unique names when two panels share the same buffer_name",
        function()
            child.lua([[
            require("agentic").setup({
                windows = {
                    chat = { buffer_name = "Shared Name" },
                    input = { buffer_name = "Shared Name" },
                },
            })
        ]])
            local key = open_session()
            child.flush()

            local chat_basename = get_panel_basename(key, "chat")
            local input_basename = get_panel_basename(key, "input")

            assert.is_true(vim.startswith(chat_basename, "Shared Name"))
            assert.is_true(vim.startswith(input_basename, "Shared Name"))
            assert.is_not.equal(chat_basename, input_basename)
        end
    )

    it("adds the session suffix to a custom buffer_name", function()
        child.lua([[
            require("agentic").setup({ windows = { chat = { buffer_name = "My Chat" } } })
        ]])
        local key1 = open_session()
        child.flush()

        child.cmd("tabnew")
        local key2 = open_session()
        child.flush()

        render_header(key1, "chat")

        assert.equal("My Chat (1)", get_panel_basename(key1, "chat"))
        assert.equal("My Chat (2)", get_panel_basename(key2, "chat"))
    end)

    it("each panel has distinct buffer name prefix", function()
        local key = open_session()
        child.flush()

        local expected_prefixes = {
            chat = "󰻞 Agentic Chat",
            input = "󰦨 Prompt",
        }

        for panel, expected_prefix in pairs(expected_prefixes) do
            local basename = get_panel_basename(key, panel)

            assert.is_not.equal("", basename)
            assert.is_true(basename:find(expected_prefix, 1, true) ~= nil)
        end
    end)
end)
