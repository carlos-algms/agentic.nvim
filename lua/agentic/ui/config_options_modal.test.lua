local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.ConfigOptionsModal", function()
    local ConfigOptionsModal = require("agentic.ui.config_options_modal")

    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type any
    local config_options
    --- @type agentic.ui.ConfigOptionsModal
    local modal
    --- @type TestSpy
    local handle_change_spy
    --- @type TestSpy
    local show_selector_spy
    --- @type TestStub|nil
    local schedule_stub
    local session_id

    local function open_modal()
        modal = ConfigOptionsModal:new({
            get_options = function()
                return config_options.options
            end,
            is_session_active = function()
                return session_id == "sess-1"
            end,
            handle_change = function(id, value, on_done)
                handle_change_spy(id, value, on_done)
            end,
            show_selector = function(option, prompt, callback)
                show_selector_spy(option, prompt, callback)
            end,
        })
        modal:open()
        bufnr = vim.api.nvim_get_current_buf()
        winid = vim.api.nvim_get_current_win()
    end

    --- @param line integer
    local function press_enter(line)
        vim.api.nvim_win_set_cursor(winid, { line, 0 })
        vim.api.nvim_buf_call(bufnr, function()
            local mapping = vim.fn.maparg("<CR>", "n", false, true)
            mapping.callback()
        end)
    end

    local function get_lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    before_each(function()
        session_id = "sess-1"
        handle_change_spy = spy.new()
        show_selector_spy = spy.new()
        config_options = {
            options = {
                {
                    id = "model",
                    type = "select",
                    currentValue = "opus",
                    name = "Model",
                    description = "Model to use",
                    options = {
                        { value = "opus", name = "Opus" },
                        { value = "sonnet", name = "Sonnet" },
                    },
                },
                {
                    id = "fast",
                    type = "boolean",
                    currentValue = false,
                    name = "Fast mode",
                },
            },
        }
    end)

    after_each(function()
        if schedule_stub then
            schedule_stub:revert()
            schedule_stub = nil
        end
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("renders select names and unchecked booleans", function()
        open_modal()

        assert.same(get_lines(), { "Model:  Opus", "Fast mode: [ ]" })
        assert.is_false(vim.bo[bufnr].modifiable)
    end)

    it("renders checked booleans", function()
        config_options.options[2].currentValue = true
        open_modal()

        assert.equal(get_lines()[2], "Fast mode: [x]")
    end)

    it("falls back to the raw select value", function()
        config_options.options[1].currentValue = "unknown"
        open_modal()

        assert.equal(get_lines()[1], "Model:  unknown")
    end)

    it("renders an empty placeholder with no dispatch", function()
        config_options.options = {}
        open_modal()

        assert.same(get_lines(), { "No settings available" })
        press_enter(1)
        assert.spy(handle_change_spy).was.called(0)
        assert.spy(show_selector_spy).was.called(0)
    end)

    it("toggles a false boolean and keeps the window open", function()
        open_modal()

        press_enter(2)

        assert.spy(handle_change_spy).was.called(1)
        assert.equal(handle_change_spy.calls[1][1], "fast")
        assert.equal(handle_change_spy.calls[1][2], true)
        assert.equal(type(handle_change_spy.calls[1][3]), "function")
        assert.is_true(vim.api.nvim_win_is_valid(winid))
    end)

    it("toggles a true boolean to false", function()
        config_options.options[2].currentValue = true
        open_modal()

        press_enter(2)

        assert.spy(handle_change_spy).was.called(1)
        assert.equal(handle_change_spy.calls[1][1], "fast")
        assert.equal(handle_change_spy.calls[1][2], false)
    end)

    it(
        "opens the existing selector and dispatches its selected value",
        function()
            open_modal()

            press_enter(1)

            assert.spy(handle_change_spy).was.called(0)
            assert.spy(show_selector_spy).was.called(1)
            assert.equal(
                show_selector_spy.calls[1][1],
                config_options.options[1]
            )
            assert.equal(show_selector_spy.calls[1][2], "Select Model:")
            assert.equal(type(show_selector_spy.calls[1][3]), "function")

            show_selector_spy.calls[1][3]("sonnet")
            assert.equal(handle_change_spy.calls[1][1], "model")
            assert.equal(handle_change_spy.calls[1][2], "sonnet")
            assert.equal(type(handle_change_spy.calls[1][3]), "function")
            assert.is_true(vim.api.nvim_win_is_valid(winid))
        end
    )

    it("rejects a selected value after the session changes", function()
        open_modal()
        press_enter(1)
        session_id = "sess-2"

        show_selector_spy.calls[1][3]("sonnet")

        assert.spy(handle_change_spy).was.called(0)
    end)

    it("rejects dispatch after the session changes", function()
        open_modal()
        session_id = "sess-2"

        press_enter(2)

        assert.spy(handle_change_spy).was.called(0)
        assert.spy(show_selector_spy).was.called(0)
    end)

    it("schedules a render after the change is confirmed", function()
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            callback()
        end)
        open_modal()
        press_enter(2)
        config_options.options[2].currentValue = true

        assert.spy(handle_change_spy).was.called(1)
        handle_change_spy.calls[1][3]()

        assert.spy(schedule_stub).was.called(1)
        assert.equal(get_lines()[2], "Fast mode: [x]")
    end)
end)
