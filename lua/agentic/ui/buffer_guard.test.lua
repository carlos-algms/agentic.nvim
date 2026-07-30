-- lua/agentic/ui/buffer_guard.test.lua
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local BufferGuard = require("agentic.ui.buffer_guard")
local ChatWidget = require("agentic.ui.chat_widget")
local WidgetLayout = require("agentic.ui.widget_layout")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- Real widgets, not stubs: the guard resolves the owner per event through
--- `WidgetRegistry`, so a fake owner bypasses the lookup under test.
--- @return agentic.ui.ChatWidget
local function new_widget()
    return ChatWidget:new(spy.new(function() end) --[[@as function]])
end

--- Unnamed, empty, `nofile`: how a panel buffer is created. `:edit` reuses it,
--- clearing buftype and setting a name — the repurpose the guard undoes.
--- @param bufnr integer
local function make_repurposable(bufnr)
    pcall(vim.api.nvim_buf_set_name, bufnr, "")
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
end

--- @return integer id Autocmd id of the single shared BufEnter guard
local function guard_autocmd_id()
    local autocmds = vim.api.nvim_get_autocmds({
        group = "AgenticBufferGuard",
        event = "BufEnter",
    })
    assert.equal(1, #autocmds)

    return autocmds[1].id
end

--- Asserts the buffer left the widget's windows for a window of its own.
--- @param widget agentic.ui.ChatWidget
--- @param bufnr integer
local function assert_redirected_out(widget, bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    assert.is_true(#wins > 0)

    for _, winid in ipairs(wins) do
        for _, widget_win in pairs(widget.win_nrs) do
            assert.is_not.equal(widget_win, winid)
        end
    end
end

--- @return string path
local function write_tmpfile()
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "-- test" }, path)
    return path
end

describe("BufferGuard", function()
    local widget
    local widget2
    local tmpfiles

    before_each(function()
        tmpfiles = {}
        vim.cmd("tabnew")
        widget = new_widget()
    end)

    after_each(function()
        for _, w in ipairs({ widget, widget2 }) do
            pcall(function()
                w:destroy()
            end)
        end
        widget = nil
        widget2 = nil

        for _, path in ipairs(tmpfiles) do
            os.remove(path)
        end

        while #vim.api.nvim_list_tabpages() > 1 do
            local ok = pcall(function()
                vim.cmd("tabclose!")
            end)
            if not ok then
                break
            end
        end
    end)

    it(
        "restores the widget buffer when a foreign buffer enters its window",
        function()
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)

            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(widget.win_nrs.chat, foreign)

            assert.equal(
                widget.buf_nrs.chat,
                vim.api.nvim_win_get_buf(widget.win_nrs.chat)
            )
        end
    )

    it(
        "does not redirect when the widget buffer enters its own window",
        function()
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)

            vim.api.nvim_win_set_buf(widget.win_nrs.chat, widget.buf_nrs.chat)

            assert.equal(
                widget.buf_nrs.chat,
                vim.api.nvim_win_get_buf(widget.win_nrs.chat)
            )
        end
    )

    it("redirects using the owning widget's target window", function()
        widget:show({ focus_prompt = false })

        vim.cmd("tabnew")
        local tab_b = vim.api.nvim_get_current_tabpage()
        widget2 = new_widget()
        widget2:show({ focus_prompt = false })

        vim.api.nvim_set_current_win(widget2.win_nrs.chat)
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(widget2.win_nrs.chat, foreign)

        -- Owner from the first registered widget instead of `vim.w.agentic_bufnr`
        -- lands the buffer in the OTHER tab.
        local wins = vim.fn.win_findbuf(foreign)
        assert.is_true(#wins > 0)
        for _, winid in ipairs(wins) do
            assert.equal(tab_b, vim.api.nvim_win_get_tabpage(winid))
        end

        assert.equal(
            widget2.buf_nrs.chat,
            vim.api.nvim_win_get_buf(widget2.win_nrs.chat)
        )
    end)

    it(
        "creates a split when the widget's tab holds no editor window",
        function()
            widget:show({ focus_prompt = false })

            local editor_win = widget:find_first_non_widget_window()
            assert.is_not_nil(editor_win)
            ---@cast editor_win integer
            vim.api.nvim_win_close(editor_win, true)

            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            local before =
                #vim.api.nvim_tabpage_list_wins(widget:get_visible_tab_id())

            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(widget.win_nrs.chat, foreign)

            assert.equal(
                widget.buf_nrs.chat,
                vim.api.nvim_win_get_buf(widget.win_nrs.chat)
            )
            assert.is_true(
                #vim.api.nvim_tabpage_list_wins(widget:get_visible_tab_id())
                    > before
            )
            assert.is_true(#vim.fn.win_findbuf(foreign) > 0)
        end
    )

    it("does not re-create the shared guard on later calls", function()
        BufferGuard.ensure()
        local first_id = guard_autocmd_id()

        BufferGuard.ensure()
        widget2 = new_widget()

        -- Counting autocmds cannot detect a re-create:
        -- `nvim_create_augroup(name, { clear = true })` returns the same id and
        -- wipes the previous autocmd, so the count stays 1 either way. Only the
        -- autocmd id changes when `ensure` is not a no-op.
        assert.equal(first_id, guard_autocmd_id())
    end)

    it("swaps a repurposed widget buffer for a fresh scratch buffer", function()
        widget:show({ focus_prompt = false })
        make_repurposable(widget.buf_nrs.chat)

        local path = write_tmpfile()
        tmpfiles[#tmpfiles + 1] = path

        local old_chat = widget.buf_nrs.chat
        vim.api.nvim_set_current_win(widget.win_nrs.chat)
        vim.cmd("edit " .. vim.fn.fnameescape(path))

        local replacement = vim.api.nvim_win_get_buf(widget.win_nrs.chat)
        assert.is_not.equal(old_chat, replacement)
        assert.equal("nofile", vim.bo[replacement].buftype)
        assert.equal(replacement, vim.w[widget.win_nrs.chat].agentic_bufnr)

        local file_wins = vim.fn.win_findbuf(old_chat)
        for _, winid in ipairs(file_wins) do
            assert.is_not.equal(widget.win_nrs.chat, winid)
        end
    end)

    it("transfers registry ownership to the replacement buffer", function()
        widget:show({ focus_prompt = false })
        make_repurposable(widget.buf_nrs.chat)

        local path = write_tmpfile()
        tmpfiles[#tmpfiles + 1] = path

        local old_chat = widget.buf_nrs.chat
        vim.api.nvim_set_current_win(widget.win_nrs.chat)
        vim.cmd("edit " .. vim.fn.fnameescape(path))

        local replacement = vim.api.nvim_win_get_buf(widget.win_nrs.chat)
        assert.equal(replacement, widget.buf_nrs.chat)
        assert.equal(widget, WidgetRegistry.get(replacement))
        assert.is_nil(WidgetRegistry.get(old_chat))
    end)

    it("redirects two consecutive edits in the same panel", function()
        widget:show({ focus_prompt = false })
        make_repurposable(widget.buf_nrs.chat)

        local first = write_tmpfile()
        local second = write_tmpfile()
        tmpfiles[#tmpfiles + 1] = first
        tmpfiles[#tmpfiles + 1] = second

        local old_chat = widget.buf_nrs.chat
        vim.api.nvim_set_current_win(widget.win_nrs.chat)
        vim.cmd("edit " .. vim.fn.fnameescape(first))

        assert_redirected_out(widget, old_chat)

        -- Without the ownership transfer above, the replacement has no owner and
        -- this second edit cannot resolve a target window.
        local replacement = vim.api.nvim_win_get_buf(widget.win_nrs.chat)
        make_repurposable(replacement)
        vim.api.nvim_set_current_win(widget.win_nrs.chat)
        vim.cmd("edit " .. vim.fn.fnameescape(second))

        local final_buf = vim.api.nvim_win_get_buf(widget.win_nrs.chat)
        assert.is_not.equal(replacement, final_buf)
        assert.equal(final_buf, widget.buf_nrs.chat)
        assert.equal(widget, WidgetRegistry.get(final_buf))

        assert_redirected_out(widget, replacement)
    end)

    it(
        "does not leak widget window options to the editor window after redirect",
        function()
            -- Widget windows hold panel-styled window-local options. A foreign
            -- buffer briefly cohabiting a widget window must not carry them to
            -- its target window — what the `vim.wo[winid][0]` `:setlocal`
            -- sentinel prevents.
            --
            -- Non-default globals below make a leak from PANEL defaults
            -- observable as a divergence on the editor window.
            local saved = {
                number = vim.o.number,
                signcolumn = vim.o.signcolumn,
                cursorline = vim.o.cursorline,
                list = vim.o.list,
            }
            vim.o.number = true
            vim.o.signcolumn = "yes"
            vim.o.cursorline = true
            vim.o.list = true

            local editor_win = vim.api.nvim_get_current_win()
            widget:show({ focus_prompt = false })

            -- Snapshot BEFORE any cohabit cycle
            local editor_before = {
                number = vim.wo[editor_win].number,
                signcolumn = vim.wo[editor_win].signcolumn,
                cursorline = vim.wo[editor_win].cursorline,
                list = vim.wo[editor_win].list,
                winhighlight = vim.wo[editor_win].winhighlight,
                statuscolumn = vim.wo[editor_win].statuscolumn,
                fillchars = vim.wo[editor_win].fillchars,
                scrolloff = vim.wo[editor_win].scrolloff,
                foldcolumn = vim.wo[editor_win].foldcolumn,
            }

            -- Triggers BufEnter inside the widget, hence a BufferGuard redirect
            -- to the editor window.
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(foreign, vim.fn.tempname() .. "_leak.txt")
            vim.api.nvim_win_set_buf(widget.win_nrs.chat, foreign)

            -- Foreign buffer lands with ORIGINAL options, not panel-styled.
            assert.equal(foreign, vim.api.nvim_win_get_buf(editor_win))
            assert.equal(editor_before.number, vim.wo[editor_win].number)
            assert.equal(
                editor_before.signcolumn,
                vim.wo[editor_win].signcolumn
            )
            assert.equal(
                editor_before.cursorline,
                vim.wo[editor_win].cursorline
            )
            assert.equal(editor_before.list, vim.wo[editor_win].list)
            assert.equal(
                editor_before.winhighlight,
                vim.wo[editor_win].winhighlight
            )
            assert.equal(
                editor_before.statuscolumn,
                vim.wo[editor_win].statuscolumn
            )
            assert.equal(editor_before.fillchars, vim.wo[editor_win].fillchars)
            assert.equal(editor_before.scrolloff, vim.wo[editor_win].scrolloff)
            assert.equal(
                editor_before.foldcolumn,
                vim.wo[editor_win].foldcolumn
            )

            WidgetLayout.close(widget.win_nrs)

            vim.o.number = saved.number
            vim.o.signcolumn = saved.signcolumn
            vim.o.cursorline = saved.cursorline
            vim.o.list = saved.list
        end
    )
end)

-- Child process: cursor-follow runs in `vim.schedule`, and flushing the event
-- loop in-process needs `vim.wait`, which escapes pcall and silently skips
-- tests. RPC round-trips flush it instead.
local Child = require("tests.helpers.child")

describe("BufferGuard cursor follow (child)", function()
    local child = Child.new()

    --- Real widget in the child, chat window focused.
    --- @return integer editor_win
    --- @return integer chat_win
    local function setup_widget_in_child()
        local wins = child.lua_get([[(function()
            local ChatWidget = require("agentic.ui.chat_widget")
            local editor_win = vim.api.nvim_get_current_win()
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })
            return { editor_win, _G.widget.win_nrs.chat }
        end)()]])

        child.api.nvim_set_current_win(wins[2])

        return wins[1], wins[2]
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("moves cursor to editor window after foreign buffer redirect", function()
        local editor_win, chat_win = setup_widget_in_child()

        local foreign = child.api.nvim_create_buf(true, false)
        child.api.nvim_win_set_buf(chat_win, foreign)

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        assert.equal(editor_win, child.api.nvim_get_current_win())
        assert.equal(foreign, child.api.nvim_win_get_buf(editor_win))
    end)

    it("moves cursor to editor window after :edit in widget window", function()
        local tmpfile = write_tmpfile()

        local editor_win = setup_widget_in_child()

        child.cmd("edit " .. child.fn.fnameescape(tmpfile))

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        assert.equal(editor_win, child.api.nvim_get_current_win())

        local editor_buf = child.api.nvim_win_get_buf(editor_win)
        local editor_name = child.api.nvim_buf_get_name(editor_buf)
        assert.equal(vim.fn.resolve(tmpfile), editor_name)

        os.remove(tmpfile)
    end)
end)
