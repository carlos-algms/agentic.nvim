-- lua/agentic/ui/buffer_guard.test.lua
local assert = require("tests.helpers.assert")
local BufferGuard = require("agentic.ui.buffer_guard")

--- Helper: create a minimal widget-like setup in a fresh tab
--- @return table state { tab, bufs, wins, augroup, cleanup }
local function create_widget_setup()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    -- Create widget buffers
    local chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[chat_buf].buftype = "nofile"
    vim.bo[chat_buf].filetype = "AgenticChat"

    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "AgenticInput"

    --- @type {chat: integer, input: integer}
    local buf_nrs = { chat = chat_buf, input = input_buf }

    -- Create widget windows
    local chat_win = vim.api.nvim_open_win(chat_buf, false, {
        split = "right",
        win = -1,
    })
    local input_win = vim.api.nvim_open_win(input_buf, false, {
        split = "below",
        win = chat_win,
    })

    --- @type agentic.ui.ChatWidget.WinNrs
    local win_nrs = { chat = chat_win, input = input_win }

    -- The original (non-widget) window is the first one
    local all_wins = vim.api.nvim_tabpage_list_wins(tab)
    local editor_win = nil
    for _, w in ipairs(all_wins) do
        if w ~= chat_win and w ~= input_win then
            editor_win = w
            break
        end
    end

    -- Mark widget windows with their expected buffer
    vim.w[chat_win].agentic_bufnr = chat_buf
    vim.w[input_win].agentic_bufnr = input_buf

    --- @type agentic.ui.BufferGuard.Callbacks
    local callbacks = {
        tab_page_id = tab,
        find_target_window = function()
            if editor_win and vim.api.nvim_win_is_valid(editor_win) then
                return editor_win
            end
            return nil
        end,
    }

    local augroup = BufferGuard.attach(callbacks)

    return {
        tab = tab,
        bufs = buf_nrs,
        wins = win_nrs,
        editor_win = editor_win,
        augroup = augroup,
        cleanup = function()
            BufferGuard.detach(augroup)
            pcall(function()
                vim.cmd("tabclose!")
            end)
        end,
    }
end

describe("BufferGuard", function()
    it(
        "restores widget buffer when foreign buffer enters " .. "widget window",
        function()
            local s = create_widget_setup()

            -- Focus the chat widget window
            vim.api.nvim_set_current_win(s.wins.chat)

            -- Create a foreign buffer and force it into the
            -- widget window via API
            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(s.wins.chat, foreign)

            -- The guard fires on BufEnter and should have
            -- swapped back synchronously
            local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
            assert.equal(s.bufs.chat, buf_in_chat)

            s.cleanup()
        end
    )

    it("redirects the foreign buffer to the editor window", function()
        local s = create_widget_setup()

        vim.api.nvim_set_current_win(s.wins.chat)

        -- Write a temp file so the foreign buffer has a name
        local tmpfile = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({ "-- test" }, tmpfile)

        vim.cmd("edit " .. vim.fn.fnameescape(tmpfile))

        -- Editor window should now display the file.
        -- Resolve symlinks before comparing (macOS: /var ->
        -- /private/var); nvim_buf_get_name returns the real path.
        local editor_buf = vim.api.nvim_win_get_buf(s.editor_win)
        local editor_name = vim.api.nvim_buf_get_name(editor_buf)
        local resolved_tmpfile = vim.fn.resolve(tmpfile)
        assert.equal(resolved_tmpfile, editor_name)

        -- Widget window should now hold a fresh replacement buffer
        local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
        assert.are_not.equal(s.bufs.chat, buf_in_chat)
        assert.equal(buf_in_chat, vim.w[s.wins.chat].agentic_bufnr)

        os.remove(tmpfile)
        s.cleanup()
    end)

    it(
        "does not redirect when widget buffer enters its own " .. "window",
        function()
            local s = create_widget_setup()

            vim.api.nvim_set_current_win(s.wins.chat)
            vim.api.nvim_win_set_buf(s.wins.chat, s.bufs.chat)

            local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
            assert.equal(s.bufs.chat, buf_in_chat)

            s.cleanup()
        end
    )

    it("creates a new split when no editor window exists", function()
        vim.cmd("tabnew")
        local tab = vim.api.nvim_get_current_tabpage()

        local chat_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[chat_buf].buftype = "nofile"

        -- Only one window — make it the widget window
        local chat_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(chat_win, chat_buf)

        -- Mark the widget window
        vim.w[chat_win].agentic_bufnr = chat_buf

        local augroup = BufferGuard.attach({
            tab_page_id = tab,
            find_target_window = function()
                -- Mimics open_editor_window: create a split
                local new_buf = vim.api.nvim_create_buf(false, true)
                local ok, winid = pcall(
                    vim.api.nvim_open_win,
                    new_buf,
                    true,
                    { split = "left", win = -1 }
                )
                if ok then
                    return winid
                end
                return nil
            end,
        })

        -- Force a foreign buffer in
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(chat_win, foreign)

        -- Widget buffer should be restored
        local buf_in_chat = vim.api.nvim_win_get_buf(chat_win)
        assert.equal(chat_buf, buf_in_chat)

        -- A new window should have been created
        local all_wins = vim.api.nvim_tabpage_list_wins(tab)
        assert.is_true(#all_wins > 1)

        BufferGuard.detach(augroup)
        pcall(function()
            vim.cmd("tabclose!")
        end)
    end)

    it("detach removes the autocmd group", function()
        local s = create_widget_setup()

        BufferGuard.detach(s.augroup)

        -- After detach, forcing a foreign buffer should NOT
        -- be intercepted
        vim.api.nvim_set_current_win(s.wins.chat)
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)

        -- The foreign buffer should stay (no guard active)
        local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
        assert.equal(foreign, buf_in_chat)

        pcall(function()
            vim.cmd("tabclose!")
        end)
    end)
end)

-- Child process tests for cursor-follow behavior.
-- vim.schedule callbacks require event loop processing that
-- can't be safely done in same-process mini.test (vim.wait
-- escapes pcall, causing silent test skips). Child process
-- tests use RPC round-trips to flush the event loop.
local Child = require("tests.helpers.child")

describe("BufferGuard cursor follow (child)", function()
    local child = Child.new()

    --- Set up widget layout in child: editor_win | chat_win.
    --- Attaches BufferGuard and focuses the chat window.
    --- @return integer editor_win
    --- @return integer chat_win
    local function setup_widget_in_child()
        local editor_win = child.api.nvim_get_current_win()

        local chat_buf = child.api.nvim_create_buf(false, true)
        child.bo[chat_buf].buftype = "nofile"

        local chat_win = child.api.nvim_open_win(chat_buf, true, {
            split = "right",
            win = -1,
        })

        -- vim.w[winid] assignment and BG.attach (which needs a
        -- callback function) can't cross the RPC boundary.
        child.lua(
            [[
            local BG = require("agentic.ui.buffer_guard")
            local editor_win, chat_win, chat_buf = ...

            vim.w[chat_win].agentic_bufnr = chat_buf

            BG.attach({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                find_target_window = function()
                    if vim.api.nvim_win_is_valid(editor_win) then
                        return editor_win
                    end
                end,
            })
        ]],
            { editor_win, chat_win, chat_buf }
        )

        child.api.nvim_set_current_win(chat_win)

        return editor_win, chat_win
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("moves cursor to editor window after foreign buffer redirect", function()
        local editor_win, chat_win = setup_widget_in_child()

        -- Force a foreign buffer into the widget window
        local foreign = child.api.nvim_create_buf(true, false)
        child.api.nvim_win_set_buf(chat_win, foreign)

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        -- Cursor should have followed the foreign buffer
        assert.equal(editor_win, child.api.nvim_get_current_win())

        -- Editor window should have the foreign buffer
        assert.equal(foreign, child.api.nvim_win_get_buf(editor_win))
    end)

    it("moves cursor to editor window after :edit in widget window", function()
        local tmpfile = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({ "-- test" }, tmpfile)

        local editor_win = setup_widget_in_child()

        -- :edit a file while in the widget window
        child.cmd("edit " .. child.fn.fnameescape(tmpfile))

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        -- Cursor should be in the editor window
        assert.equal(editor_win, child.api.nvim_get_current_win())

        -- Editor window should display the file
        local editor_buf = child.api.nvim_win_get_buf(editor_win)
        local editor_name = child.api.nvim_buf_get_name(editor_buf)
        assert.equal(vim.fn.resolve(tmpfile), editor_name)

        os.remove(tmpfile)
    end)
end)
