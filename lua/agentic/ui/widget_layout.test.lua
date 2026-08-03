local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local BufHelpers = require("agentic.utils.buf_helpers")
local WidgetLayout = require("agentic.ui.widget_layout")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local ToolBlockBorder = require("agentic.ui.tool_block_border")

describe("WidgetLayout", function()
    local notify_stub
    local saved_chat_win_opts
    --- Baseline tabpage handles, not just a count: `tabclose!` closes whichever
    --- tabpage is current, so a case that ends on a baseline tab while an extra
    --- one is still open would otherwise have the baseline closed instead and
    --- leak the test tab with the count back at baseline.
    local base_tab_set
    --- @type table<integer, boolean>
    local base_buf_set
    --- @type table<integer, boolean>
    local base_win_set
    --- Stubs on `vim.api` reverted by teardown. Reverting only after the call
    --- under test leaks them to the rest of the run when that call raises, and
    --- these cases stub `nvim_win_is_valid` itself, so the leak breaks teardown
    --- and every later case rather than just this one.
    local api_stubs

    --- @param name string `vim.api` function to stub
    --- @return table stub
    local function stub_api(name)
        local stub = spy.stub(vim.api, name)
        table.insert(api_stubs, stub)
        return stub
    end

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
        saved_chat_win_opts = nil
        api_stubs = {}

        base_tab_set = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            base_tab_set[tab] = true
        end

        base_buf_set = {}
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            base_buf_set[bufnr] = true
        end

        base_win_set = {}
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
            base_win_set[winid] = true
        end
    end)

    after_each(function()
        -- Before the tab cleanup below, which calls the stubbed APIs.
        for _, stub in ipairs(api_stubs) do
            stub:revert()
        end
        api_stubs = {}

        notify_stub:revert()
        if saved_chat_win_opts then
            Config.windows.chat.win_opts = saved_chat_win_opts
        end

        for _, winid in ipairs(vim.api.nvim_list_wins()) do
            if not base_win_set[winid] and BufHelpers.is_win_usable(winid) then
                pcall(vim.api.nvim_win_close, winid, true)
            end
        end

        -- Nearly every case here opens a tabpage. Closing them only at the end
        -- of each `it` leaks them to the rest of the run whenever an assertion
        -- goes red, so teardown is the backstop.
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tab_set[tab] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tab)
                    vim.cmd("tabclose!")
                end)
            end
        end

        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_buf_set[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end)

    describe("calculate_width", function()
        --- @type integer
        local cols
        local default_width_pct =
            tonumber(string.sub(Config.windows.width, 1, -2))

        before_each(function()
            cols = vim.o.columns
        end)

        it("should handle percentage strings", function()
            local width = WidgetLayout.calculate_width(Config.windows.width)
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
        end)

        it("should handle decimal values", function()
            local width = WidgetLayout.calculate_width(0.3)
            assert.are.equal(math.floor(cols * 0.3), width)
        end)

        it("should handle absolute numbers", function()
            local width = WidgetLayout.calculate_width(80)
            assert.are.equal(80, width)
        end)

        it("should default for invalid values", function()
            local width = WidgetLayout.calculate_width("invalid")
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local width = WidgetLayout.calculate_width(0.01)
            assert.are.equal(math.max(1, math.floor(cols * 0.01)), width)
        end)
    end)

    describe("calculate_height", function()
        --- @type integer
        local lines
        local default_height_pct =
            tonumber(string.sub(Config.windows.height, 1, -2))

        before_each(function()
            lines = vim.o.lines
        end)

        it("should handle percentage strings", function()
            local height = WidgetLayout.calculate_height(Config.windows.height)
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
        end)

        it("should handle decimal values", function()
            local height = WidgetLayout.calculate_height(0.4)
            assert.are.equal(math.floor(lines * 0.4), height)
        end)

        it("should handle absolute numbers", function()
            local height = WidgetLayout.calculate_height(25)
            assert.are.equal(25, height)
        end)

        it("should default for invalid values", function()
            local height = WidgetLayout.calculate_height("invalid")
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local height = WidgetLayout.calculate_height(0.01)
            assert.are.equal(math.max(1, math.floor(lines * 0.01)), height)
        end)
    end)

    describe("close", function()
        it("should close all valid windows", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
            })

            local win_nrs = { test = winid }
            WidgetLayout.close(win_nrs)

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.test)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { test = 99999 }
            WidgetLayout.close(win_nrs)
            assert.is_nil(win_nrs.test)
        end)

        it("should clear all entries from win_nrs table", function()
            local bufnr1 = vim.api.nvim_create_buf(false, true)
            local bufnr2 = vim.api.nvim_create_buf(false, true)
            local winid1 = vim.api.nvim_open_win(bufnr1, false, {
                split = "right",
                win = -1,
            })
            local winid2 = vim.api.nvim_open_win(bufnr2, false, {
                split = "below",
                win = winid1,
            })

            local win_nrs = { win1 = winid1, win2 = winid2 }
            WidgetLayout.close(win_nrs)

            assert.is_nil(win_nrs.win1)
            assert.is_nil(win_nrs.win2)
        end)
    end)

    describe("close_optional_window", function()
        it("should close valid window", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
            })

            local win_nrs = { code = winid }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { code = 99999 }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")
            assert.is_nil(win_nrs.code)
        end)

        it("should handle nil windows", function()
            local win_nrs = { code = nil }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")
            assert.is_nil(win_nrs.code)
        end)

        -- On 0.11.x `tabclose` leaves handles that answer `nvim_win_is_valid`
        -- but segfault in `nvim_win_close`. A panel close driven by an async
        -- content update after the user closed the tab hits exactly such a
        -- handle, so the tabpage must be consulted too.
        it("skips a valid handle whose tabpage is gone", function()
            vim.cmd("tabnew")
            local winid = vim.api.nvim_get_current_win()
            local dead_tab = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabclose!")

            stub_api("nvim_win_is_valid"):returns(true)
            stub_api("nvim_win_get_tabpage"):returns(dead_tab)
            local close_stub = stub_api("nvim_win_close")

            local win_nrs = { code = winid }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")

            assert.equal(0, close_stub.call_count)
            assert.is_nil(win_nrs.code)
        end)

        it("should restore chat height in bottom layout", function()
            local chat_buf = vim.api.nvim_create_buf(false, true)
            local code_buf = vim.api.nvim_create_buf(false, true)

            local chat_winid = vim.api.nvim_open_win(chat_buf, false, {
                split = "below",
                win = -1,
                height = 20,
            })
            local code_winid = vim.api.nvim_open_win(code_buf, false, {
                split = "below",
                win = chat_winid,
                height = 5,
            })

            local before_height = vim.api.nvim_win_get_height(chat_winid)

            local win_nrs = { chat = chat_winid, code = code_winid }
            WidgetLayout.close_optional_window(win_nrs, "code", "bottom")

            assert.equal(before_height, vim.api.nvim_win_get_height(chat_winid))

            pcall(vim.api.nvim_win_close, chat_winid, true)
        end)
    end)

    describe("open", function()
        it(
            "skips deferred input focus when its tabpage is no longer current",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                api_stubs[#api_stubs + 1] = schedule_stub
                local insert_stub =
                    spy.stub(BufHelpers, "start_insert_on_last_char")
                api_stubs[#api_stubs + 1] = insert_stub

                vim.cmd("tabnew")
                local target_tab = vim.api.nvim_get_current_tabpage()

                local win_nrs = {}
                local buf_nrs = {
                    chat = vim.api.nvim_create_buf(false, true),
                    input = vim.api.nvim_create_buf(false, true),
                    code = vim.api.nvim_create_buf(false, true),
                    files = vim.api.nvim_create_buf(false, true),
                    diagnostics = vim.api.nvim_create_buf(false, true),
                    todos = vim.api.nvim_create_buf(false, true),
                }

                WidgetLayout.open({
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    position = "right",
                })

                local input_win = win_nrs.input
                assert.is_not_nil(input_win)
                local focus_callback =
                    schedule_stub.calls[schedule_stub.call_count][1]

                vim.cmd("tabnew")
                local current_tab = vim.api.nvim_get_current_tabpage()
                assert.is_not.equal(target_tab, current_tab)

                local set_current_stub = stub_api("nvim_set_current_win")

                focus_callback()

                assert.equal(0, set_current_stub.call_count)
                assert.equal(0, insert_stub.call_count)
                assert.equal(current_tab, vim.api.nvim_get_current_tabpage())
            end
        )

        it(
            "creates a fresh chat window when the cached one is in another tab",
            function()
                vim.cmd("tabnew")

                local win_nrs = {}
                local files_buf = vim.api.nvim_create_buf(false, true)
                -- Non-empty, else `open_or_resize_dynamic_window` takes the
                -- close-and-forget branch and never reaches the reuse check.
                vim.api.nvim_buf_set_lines(
                    files_buf,
                    0,
                    -1,
                    false,
                    { "- some/file.lua" }
                )

                local buf_nrs = {
                    chat = vim.api.nvim_create_buf(false, true),
                    input = vim.api.nvim_create_buf(false, true),
                    code = vim.api.nvim_create_buf(false, true),
                    files = files_buf,
                    diagnostics = vim.api.nvim_create_buf(false, true),
                    todos = vim.api.nvim_create_buf(false, true),
                }

                WidgetLayout.open({
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    position = "right",
                    focus_prompt = false,
                })

                local first_chat = win_nrs.chat
                local first_files = win_nrs.files
                assert.is_not_nil(first_chat)
                assert.is_not_nil(first_files)

                vim.cmd("tabnew")
                local second_tab = vim.api.nvim_get_current_tabpage()

                WidgetLayout.open({
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    position = "right",
                    focus_prompt = false,
                })

                -- A valid handle from another tab renders nothing where the user
                -- is looking, so it must not be reused.
                assert.is_not.equal(first_chat, win_nrs.chat)
                assert.equal(
                    second_tab,
                    vim.api.nvim_win_get_tabpage(win_nrs.chat)
                )
                assert.equal(
                    second_tab,
                    vim.api.nvim_win_get_tabpage(win_nrs.input)
                )

                -- Dynamic panels gained the same ownership only in this fix:
                -- reusing the foreign handle split one widget's topology across
                -- two tabs, leaving an untracked panel behind.
                assert.is_not.equal(first_files, win_nrs.files)
                assert.equal(
                    second_tab,
                    vim.api.nvim_win_get_tabpage(win_nrs.files)
                )
                assert.is_false(vim.api.nvim_win_is_valid(first_files))

                assert.equal(0, notify_stub.call_count)

                WidgetLayout.close(win_nrs)
                pcall(function()
                    vim.cmd("tabclose")
                end)
                pcall(function()
                    vim.cmd("tabclose")
                end)
            end
        )

        -- A background session emptying a panel is an async content update, so
        -- the cached handle can belong to a tab the user has since closed. On
        -- 0.11.x such a handle still answers `nvim_win_is_valid` and segfaults
        -- in `nvim_win_close`; the cursor must also stay in the user's tab.
        it("clears an empty panel whose tabpage is gone", function()
            vim.cmd("tabnew")
            local dead_tab = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabclose!")
            local live_tab = vim.api.nvim_get_current_tabpage()

            -- A handle no window ever had, forced stale-valid: the tabpage is the
            -- only axis left that can reject it.
            local dead_win = 99999
            local real_is_valid = vim.api.nvim_win_is_valid
            stub_api("nvim_win_is_valid"):invokes(function(win)
                return win == dead_win or real_is_valid(win)
            end)
            local real_get_tabpage = vim.api.nvim_win_get_tabpage
            stub_api("nvim_win_get_tabpage"):invokes(function(win)
                if win == dead_win then
                    return dead_tab
                end
                return real_get_tabpage(win)
            end)
            local close_stub = stub_api("nvim_win_close")

            local win_nrs = { files = dead_win }
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            assert.is_nil(win_nrs.files)
            assert.is_false(close_stub:called_with(dead_win, true))
            assert.equal(live_tab, vim.api.nvim_get_current_tabpage())
            assert.equal(0, notify_stub.call_count)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        -- A session moved to another tab reopens its panels there. The handles
        -- cached from the previous tab are still valid and still hold the same
        -- buffers, so leaving them open shows a second copy of the widget in the
        -- tab the user left, untracked by `win_nrs`.
        it("closes cached panel windows left in another tabpage", function()
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }
            local win_nrs = {}

            vim.cmd("tabnew")

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            local old_chat = win_nrs.chat
            local old_input = win_nrs.input
            assert.is_true(vim.api.nvim_win_is_valid(old_chat))
            assert.is_true(vim.api.nvim_win_is_valid(old_input))

            vim.cmd("tabnew")
            local second_tab = vim.api.nvim_get_current_tabpage()

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            assert.is_false(vim.api.nvim_win_is_valid(old_chat))
            assert.is_false(vim.api.nvim_win_is_valid(old_input))
            assert.equal(second_tab, vim.api.nvim_win_get_tabpage(win_nrs.chat))

            WidgetLayout.close(win_nrs)
        end)

        it("should fall back to right for invalid position", function()
            vim.cmd("tabnew")

            local win_nrs = {}
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            assert.has_no_errors(function()
                WidgetLayout.open({
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    --- @diagnostic disable-next-line: assign-type-mismatch
                    position = "invalid",
                })
            end)

            assert.is_not_nil(win_nrs.chat)
            assert.is_not_nil(win_nrs.input)
            assert.equal(1, notify_stub.call_count)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("preserves chat manual folds across close + reopen", function()
            local saved_folding = Config.folding
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    threshold = 5,
                    fold_on_error = false,
                },
            }

            vim.cmd("tabnew")

            local chat_buf = vim.api.nvim_create_buf(false, true)
            vim.bo[chat_buf].buftype = "nofile"
            vim.bo[chat_buf].bufhidden = "hide"
            vim.api.nvim_buf_set_lines(
                chat_buf,
                0,
                -1,
                false,
                vim.fn["repeat"]({ "L" }, 60)
            )

            local win_nrs = {}
            local buf_nrs = {
                chat = chat_buf,
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            local Fold = require("agentic.ui.tool_call_fold")
            Fold.close_range(chat_buf, 10, 25)
            Fold.close_range(chat_buf, 35, 50)

            local first_chat_win = win_nrs.chat
            vim.api.nvim_win_call(first_chat_win, function()
                assert.equal(vim.fn.foldclosed(15), 10)
                assert.equal(vim.fn.foldclosed(40), 35)
            end)

            WidgetLayout.close(win_nrs)

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            assert.is_not_nil(win_nrs.chat)
            vim.api.nvim_win_call(win_nrs.chat, function()
                assert.equal(vim.fn.foldclosed(15), 10)
                assert.equal(vim.fn.foldclosedend(15), 25)
                assert.equal(vim.fn.foldclosed(35), 35)
                assert.equal(vim.fn.foldclosedend(35), 50)
            end)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
            Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        end)

        it(
            "applies the tool block statuscolumn only to the chat window",
            function()
                vim.cmd("tabnew")

                local win_nrs = {}
                local buf_nrs = {
                    chat = vim.api.nvim_create_buf(false, true),
                    input = vim.api.nvim_create_buf(false, true),
                    code = vim.api.nvim_create_buf(false, true),
                    files = vim.api.nvim_create_buf(false, true),
                    diagnostics = vim.api.nvim_create_buf(false, true),
                    todos = vim.api.nvim_create_buf(false, true),
                }

                WidgetLayout.open({
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    position = "right",
                    focus_prompt = false,
                })

                assert.equal(
                    ToolBlockBorder.STATUSCOLUMN_EXPR,
                    vim.wo[win_nrs.chat].statuscolumn
                )
                assert.equal("", vim.wo[win_nrs.input].statuscolumn)

                assert.is_not_nil(
                    string.find(
                        vim.wo[win_nrs.chat].winhighlight,
                        "LineNr:Normal",
                        1,
                        true
                    )
                )

                WidgetLayout.close(win_nrs)
                pcall(function()
                    vim.cmd("tabclose")
                end)
            end
        )

        it("sizes panel to visual rows when content wraps", function()
            vim.cmd("tabnew")

            local files_buf = vim.api.nvim_create_buf(false, true)
            local long = string.rep("a/very/long/path/segment/", 20)
            vim.api.nvim_buf_set_lines(
                files_buf,
                0,
                -1,
                false,
                { "- " .. long, "- " .. long }
            )

            local win_nrs = {}
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = files_buf,
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            local files_win = win_nrs.files
            assert.is_not_nil(files_win)
            ---@cast files_win integer

            local visual = vim.api.nvim_win_text_height(files_win, {}).all
            local height = vim.api.nvim_win_get_height(files_win)
            local expected = math.min(visual, Config.windows.files.max_height)

            assert.is_true(height >= expected)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("honors a user-provided chat statuscolumn option", function()
            saved_chat_win_opts = vim.deepcopy(Config.windows.chat.win_opts)
            Config.windows.chat.win_opts =
                vim.tbl_deep_extend("force", saved_chat_win_opts or {}, {
                    statuscolumn = "USER",
                })

            vim.cmd("tabnew")

            local win_nrs = {}
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            WidgetLayout.open({
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            assert.equal("USER", vim.wo[win_nrs.chat].statuscolumn)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)
    end)

    describe("open_hidden_chat_window", function()
        it("opens a hidden float on the chat buffer", function()
            local chat_buf = vim.api.nvim_create_buf(false, true)
            vim.bo[chat_buf].buftype = "nofile"
            vim.bo[chat_buf].bufhidden = "hide"

            local winid = WidgetLayout.open_hidden_chat_window(chat_buf)
            assert.is_not_nil(winid)
            ---@cast winid integer

            assert.is_true(vim.api.nvim_win_is_valid(winid))

            local cfg = vim.api.nvim_win_get_config(winid)
            assert.equal(cfg.relative, "editor")
            assert.is_true(cfg.hide)
            assert.equal(vim.api.nvim_win_get_buf(winid), chat_buf)
            assert.equal(vim.w[winid].agentic_bufnr, chat_buf)

            pcall(vim.api.nvim_win_close, winid, true)
            pcall(vim.api.nvim_buf_delete, chat_buf, { force = true })
        end)

        describe("with folding enabled", function()
            --- @type agentic.UserConfig.Folding|nil
            local saved_folding

            before_each(function()
                saved_folding = Config.folding
                Config.folding = {
                    tool_calls = {
                        enabled = true,
                        threshold = 5,
                        fold_on_error = false,
                    },
                }
            end)

            after_each(function()
                Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
            end)

            it("applies manual fold options to the hidden float", function()
                local chat_buf = vim.api.nvim_create_buf(false, true)
                vim.bo[chat_buf].buftype = "nofile"
                vim.bo[chat_buf].bufhidden = "hide"

                local winid = WidgetLayout.open_hidden_chat_window(chat_buf)

                assert.equal(vim.wo[winid].foldmethod, "manual")
                assert.equal(vim.wo[winid].foldlevel, 0)
                assert.is_true(vim.wo[winid].foldenable)

                pcall(vim.api.nvim_win_close, winid, true)
                pcall(vim.api.nvim_buf_delete, chat_buf, { force = true })
            end)

            it(
                "allows folding the buffer while no visible window is open",
                function()
                    local chat_buf = vim.api.nvim_create_buf(false, true)
                    vim.bo[chat_buf].buftype = "nofile"
                    vim.bo[chat_buf].bufhidden = "hide"
                    vim.api.nvim_buf_set_lines(
                        chat_buf,
                        0,
                        -1,
                        false,
                        vim.fn["repeat"]({ "L" }, 30)
                    )

                    local hidden_winid =
                        WidgetLayout.open_hidden_chat_window(chat_buf)
                    assert.is_not_nil(hidden_winid)
                    ---@cast hidden_winid integer

                    local Fold = require("agentic.ui.tool_call_fold")
                    Fold.close_range(chat_buf, 5, 15)

                    vim.api.nvim_win_call(hidden_winid, function()
                        assert.equal(vim.fn.foldclosed(10), 5)
                    end)

                    pcall(vim.api.nvim_win_close, hidden_winid, true)
                    pcall(vim.api.nvim_buf_delete, chat_buf, { force = true })
                end
            )
        end)
    end)
end)

describe("WidgetLayout deferred window guards", function()
    local schedule_stub
    local scheduled
    local base_tabs
    local base_bufs
    local usable_stub
    local close_stub

    --- @return agentic.ui.ChatWidget.BufNrs
    local function make_buffers()
        return {
            chat = vim.api.nvim_create_buf(false, true),
            input = vim.api.nvim_create_buf(false, true),
            code = vim.api.nvim_create_buf(false, true),
            files = vim.api.nvim_create_buf(false, true),
            diagnostics = vim.api.nvim_create_buf(false, true),
            todos = vim.api.nvim_create_buf(false, true),
        }
    end

    before_each(function()
        base_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tabpage] = true
        end
        base_bufs = {}
        usable_stub = nil
        close_stub = nil
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            base_bufs[bufnr] = true
        end
        scheduled = nil
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            scheduled = callback
        end)
    end)

    after_each(function()
        if close_stub then
            close_stub:revert()
            close_stub = nil
        end
        if usable_stub then
            usable_stub:revert()
            usable_stub = nil
        end
        schedule_stub:revert()
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tabs[tabpage] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end
        local remaining_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            remaining_tabs[tabpage] = true
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
        local extra_bufs = 0
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] then
                extra_bufs = extra_bufs + 1
            end
        end
        assert.same(remaining_tabs, base_tabs)
        assert.equal(0, extra_bufs)
    end)

    it("replaces a cached handle owned by another tabpage", function()
        vim.cmd("tabnew")
        local foreign_win = vim.api.nvim_get_current_win()
        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local win_nrs = { chat = foreign_win }

        WidgetLayout.open({
            tab_page_id = owner_tab,
            buf_nrs = make_buffers(),
            win_nrs = win_nrs,
            position = "right",
            focus_prompt = false,
        })

        assert.is_false(BufHelpers.is_win_usable(foreign_win))
        assert.is_not.equal(foreign_win, win_nrs.chat)
        assert.equal(owner_tab, vim.api.nvim_win_get_tabpage(win_nrs.chat))
    end)

    it("does not focus input after the current tab changes", function()
        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local win_nrs = {}
        WidgetLayout.open({
            tab_page_id = owner_tab,
            buf_nrs = make_buffers(),
            win_nrs = win_nrs,
            position = "right",
            focus_prompt = true,
        })
        assert.equal("function", type(scheduled))

        vim.cmd("tabnew")
        local foreign_tab = vim.api.nvim_get_current_tabpage()
        scheduled()

        assert.equal(foreign_tab, vim.api.nvim_get_current_tabpage())
    end)

    it("does not focus input after the owner tab closes", function()
        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local win_nrs = {}
        WidgetLayout.open({
            tab_page_id = owner_tab,
            buf_nrs = make_buffers(),
            win_nrs = win_nrs,
            position = "right",
            focus_prompt = true,
        })
        assert.equal("function", type(scheduled))

        vim.cmd("tabclose!")
        local safe_tab = vim.api.nvim_get_current_tabpage()
        local safe_win = vim.api.nvim_get_current_win()
        scheduled()

        assert.equal(safe_tab, vim.api.nvim_get_current_tabpage())
        assert.equal(safe_win, vim.api.nvim_get_current_win())
    end)

    it("gates close through window usability", function()
        vim.cmd("tabnew")
        local winid = vim.api.nvim_get_current_win()
        usable_stub = spy.stub(BufHelpers, "is_win_usable")
        usable_stub:returns(false)
        close_stub = spy.stub(vim.api, "nvim_win_close")

        WidgetLayout.close({ chat = winid })

        local usable_called = usable_stub:called_with(winid)
        local close_count = close_stub.call_count
        close_stub:revert()
        close_stub = nil
        usable_stub:revert()
        usable_stub = nil
        assert.is_true(usable_called)
        assert.equal(0, close_count)
    end)
end)
