local assert = require("tests.helpers.assert")
local WidgetLayout = require("agentic.ui.widget_layout")
local Config = require("agentic.config")

describe("WidgetLayout", function()
    local original_config

    before_each(function()
        original_config = vim.deepcopy(Config)
    end)

    after_each(function()
        for key, value in pairs(original_config) do
            Config[key] = value
        end
    end)

    describe("calculate_width", function()
        it("should handle percentage strings", function()
            vim.o.columns = 100
            local width = WidgetLayout.calculate_width("40%")
            assert.are.equal(40, width)
        end)

        it("should handle decimal values", function()
            vim.o.columns = 100
            local width = WidgetLayout.calculate_width(0.3)
            assert.are.equal(30, width)
        end)

        it("should handle absolute numbers", function()
            vim.o.columns = 100
            local width = WidgetLayout.calculate_width(80)
            assert.are.equal(80, width)
        end)

        it("should default to 40% for invalid values", function()
            vim.o.columns = 100
            local width = WidgetLayout.calculate_width("invalid")
            assert.are.equal(40, width)
        end)

        it("should return at least 1", function()
            vim.o.columns = 100
            local width = WidgetLayout.calculate_width(0.01)
            assert.are.equal(1, width)
        end)
    end)

    describe("calculate_height", function()
        it("should handle percentage strings", function()
            vim.o.lines = 50
            local height = WidgetLayout.calculate_height("30%")
            assert.are.equal(15, height)
        end)

        it("should handle decimal values", function()
            vim.o.lines = 50
            local height = WidgetLayout.calculate_height(0.4)
            assert.are.equal(20, height)
        end)

        it("should handle absolute numbers", function()
            vim.o.lines = 50
            local height = WidgetLayout.calculate_height(25)
            assert.are.equal(25, height)
        end)

        it("should default to 30% for invalid values", function()
            vim.o.lines = 50
            local height = WidgetLayout.calculate_height("invalid")
            assert.are.equal(15, height)
        end)

        it("should return at least 1", function()
            vim.o.lines = 10
            local height = WidgetLayout.calculate_height(0.01)
            assert.are.equal(1, height)
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
            WidgetLayout.close_optional_window(win_nrs, "code")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { code = 99999 }
            WidgetLayout.close_optional_window(win_nrs, "code")
            -- Window ID is cleared even if invalid
            assert.is_nil(win_nrs.code)
        end)

        it("should handle nil windows", function()
            local win_nrs = { code = nil }
            WidgetLayout.close_optional_window(win_nrs, "code")
            assert.is_nil(win_nrs.code)
        end)
    end)

    describe("resize_dynamic_window", function()
        it("should close window when buffer is empty", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
                height = 10,
            })

            local buf_nrs = { code = bufnr }
            local win_nrs = { code = winid }

            WidgetLayout.resize_dynamic_window(buf_nrs, win_nrs, "code")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("should not resize when window is invalid", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "line1", "line2" }
            )

            local buf_nrs = { code = bufnr }
            local win_nrs = { code = 99999 }

            WidgetLayout.resize_dynamic_window(buf_nrs, win_nrs, "code")
        end)

        it("should resize window based on buffer content", function()
            Config.windows.code = { max_height = 20 }
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "line1", "line2", "line3" }
            )

            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
                height = 10,
            })

            local buf_nrs = { code = bufnr }
            local win_nrs = { code = winid }

            WidgetLayout.resize_dynamic_window(buf_nrs, win_nrs, "code")

            local win_config = vim.api.nvim_win_get_config(winid)
            assert.are.equal(4, win_config.height)
        end)

        it("should respect max_height constraint", function()
            Config.windows.code = { max_height = 2 }
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "line1",
                "line2",
                "line3",
                "line4",
                "line5",
            })

            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
                height = 10,
            })

            local buf_nrs = { code = bufnr }
            local win_nrs = { code = winid }

            WidgetLayout.resize_dynamic_window(buf_nrs, win_nrs, "code")

            local win_config = vim.api.nvim_win_get_config(winid)
            assert.are.equal(2, win_config.height)
        end)
    end)
end)
