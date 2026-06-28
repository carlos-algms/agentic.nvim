--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local PermissionSection = require("tests.helpers.permission_section")

local TITLE_FENCE = string.rep("`", 5)

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll
    --- @type agentic.UserConfig.ToolCalls|nil
    local original_tool_calls

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        original_tool_calls = Config.tool_calls
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        Config.tool_calls = original_tool_calls --- @diagnostic disable-line: assign-type-mismatch
        if writer then
            writer:destroy()
        end
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @return string[]
    local function get_all_lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    --- @return string
    local function get_all_content()
        return table.concat(get_all_lines(), "\n")
    end

    --- @param pattern string
    --- @return boolean
    local function content_has(pattern)
        for _, line in ipairs(get_all_lines()) do
            if line:find(pattern) then
                return true
            end
        end
        return false
    end

    --- @param pattern string
    --- @return integer
    local function count_matching_lines(pattern)
        local count = 0
        for _, line in ipairs(get_all_lines()) do
            if line:match(pattern) then
                count = count + 1
            end
        end
        return count
    end

    --- @param text string
    --- @param session_update string|nil
    --- @return agentic.acp.SessionUpdateMessage
    local function make_update(text, session_update)
        return {
            sessionUpdate = session_update or "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_thought_update(text)
        return {
            sessionUpdate = "agent_thought_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    --- @param tool_call_id string
    --- @return integer
    local function block_end_row(tool_call_id)
        local tracker = writer.tool_call_blocks[tool_call_id]
        local NS = vim.api.nvim_create_namespace("agentic_tool_blocks")
        local pos = vim.api.nvim_buf_get_extmark_by_id(
            bufnr,
            NS,
            tracker.extmark_id,
            { details = true }
        )
        --- @type integer
        local end_row = pos[3].end_row
        return end_row
    end

    --- @return table<integer, true> rows
    local function comment_highlight_rows()
        local ns = vim.api.nvim_create_namespace("agentic_diff_highlights")
        local extmarks =
            vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
        local rows = {}
        for _, extmark in ipairs(extmarks) do
            if extmark[4].hl_group == "Comment" then
                rows[extmark[2]] = true
            end
        end
        return rows
    end

    --- @param line string
    --- @return integer|nil row
    local function find_row(line)
        local lines = get_all_lines()
        for row, current in ipairs(lines) do
            if current == line then
                return row - 1
            end
        end
        return nil
    end

    --- @param line string
    --- @return boolean highlighted
    local function line_has_comment_highlight(line)
        local row = find_row(line)
        if not row then
            return false
        end
        return comment_highlight_rows()[row] == true
    end

    local ALLOW_REJECT_OPTIONS = {
        {
            optionId = "allow-once",
            name = "Allow once",
            kind = "allow_once",
        },
        {
            optionId = "reject-once",
            name = "Reject once",
            kind = "reject_once",
        },
    }

    --- @param id string
    --- @param state { is_focused: boolean, focused_button_index?: integer, sorted_options?: table[] }
    local function setup_permission_block(id, state)
        writer:write_tool_call_block(make_tool_call_block(id, "pending"))
        writer:set_permission_state(id, {
            sorted_options = state.sorted_options or ALLOW_REJECT_OPTIONS,
            is_focused = state.is_focused,
            focused_button_index = state.focused_button_index,
        })
        writer:repaint_status_row(id)
    end

    local NS_THINKING = vim.api.nvim_create_namespace("agentic_thinking")

    --- @return vim.api.keyset.get_extmark_item[]
    local function get_thinking_extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            NS_THINKING,
            0,
            -1,
            { details = true }
        )
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check cursor across tabpages", function()
            setup_buffer(50, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)

        it(
            "returns false when cursor is on any permission row (button or status)",
            function()
                setup_permission_block("auto-scroll-permission-row", {
                    is_focused = false,
                })
                local tracker =
                    writer.tool_call_blocks["auto-scroll-permission-row"]
                --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                local k = tracker._rendered_button_count or 0
                assert.is_true(k > 0)
                local end_row = block_end_row("auto-scroll-permission-row")
                local first_button_row = end_row - k
                -- Park cursor on the first button row (1-indexed for the API).
                vim.api.nvim_win_set_cursor(winid, {
                    first_button_row + 1,
                    0,
                })

                assert.is_false(writer:_check_auto_scroll(bufnr))

                -- Status row sits at the upper bound of the rendered button
                -- range scan in _cursor_on_permission_button_row, so parking
                -- there must also exempt from auto-scroll.
                vim.api.nvim_win_set_cursor(winid, { end_row + 1, 0 })
                assert.is_false(writer:_check_auto_scroll(bufnr))
            end
        )

        it(
            "returns true when cursor sits above the permission rows in the block body",
            function()
                setup_permission_block("auto-scroll-above-perm", {
                    is_focused = false,
                })
                local tracker =
                    writer.tool_call_blocks["auto-scroll-above-perm"]
                --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                local k = tracker._rendered_button_count or 0
                local end_row = block_end_row("auto-scroll-above-perm")
                local bottom_pad_row = end_row - k - 1
                -- Park cursor on the body row above the bottom_pad row
                -- (0-indexed bottom_pad_row - 1 -> 1-indexed bottom_pad_row
                -- for the cursor API). Outside the rendered button range
                -- and still within the auto-scroll threshold of the
                -- buffer end.
                vim.api.nvim_win_set_cursor(winid, { bottom_pad_row, 0 })

                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it(
            "still auto-scrolls when cursor is on a non-permission status row",
            function()
                writer:write_tool_call_block(
                    make_tool_call_block("auto-scroll-status-row", "pending")
                )
                vim.api.nvim_win_set_cursor(winid, {
                    block_end_row("auto-scroll-status-row") + 1,
                    0,
                })

                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )
    end)

    describe("status row", function()
        --- @param tool_call_id string
        --- @return string
        local function status_row_text(tool_call_id)
            local text = PermissionSection.status_row_text(
                bufnr,
                block_end_row(tool_call_id)
            )
            assert.is_not_nil(text)
            --- @cast text string
            return text
        end

        --- All NS_STATUS extmarks on the K rendered rows above the status
        --- row of the block.
        --- @param tool_call_id string
        --- @return vim.api.keyset.get_extmark_item[]
        local function button_row_marks(tool_call_id)
            local tracker = writer.tool_call_blocks[tool_call_id]
            --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
            return PermissionSection.button_row_extmarks(
                bufnr,
                block_end_row(tool_call_id),
                tracker._rendered_button_count or 0
            )
        end

        --- @param marks vim.api.keyset.get_extmark_item[]
        --- @param hl_group string
        --- @return integer
        local function count_hl_marks(marks, hl_group)
            local count = 0
            for _, em in ipairs(marks) do
                if em[4].hl_group == hl_group then
                    count = count + 1
                end
            end
            return count
        end

        it(
            "writes the status word as real text at row N for non-pending blocks",
            function()
                writer:write_tool_call_block(
                    make_tool_call_block("row-n-completed", "completed")
                )

                local text = status_row_text("row-n-completed")
                assert.truthy(text:find("completed"))
                assert.is_true(#text > 0)
            end
        )

        it("writes pending status word as real text at row N", function()
            writer:write_tool_call_block(
                make_tool_call_block("row-n-pending", "pending")
            )

            assert.truthy(status_row_text("row-n-pending"):find("pending"))
        end)

        it("defaults missing initial tool call fields before render", function()
            writer:write_tool_call_block({
                tool_call_id = "row-n-missing-fields",
            })

            local tracker = writer.tool_call_blocks["row-n-missing-fields"]
            assert.is_not_nil(tracker)
            --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
            assert.equal("other", tracker.kind)
            assert.equal("Pending", tracker.argument)
            assert.equal("pending", tracker.status)
            assert.truthy(get_all_content():find("other(Pending)", 1, true))
            assert.truthy(
                status_row_text("row-n-missing-fields"):find("pending")
            )
        end)

        --- @param tool_call_id string
        --- @return string[]
        local function button_row_lines(tool_call_id)
            local tracker = writer.tool_call_blocks[tool_call_id]
            --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
            return PermissionSection.button_row_lines(
                bufnr,
                block_end_row(tool_call_id),
                tracker._rendered_button_count or 0
            )
        end

        for _, case in ipairs({
            {
                name = "renders buttons one per row for pending non-focused permission state",
                id = "row-n-inactive",
                is_focused = false,
                status_pattern = "pending",
                expect_digit_prefix = false,
                post_action = nil,
            },
            {
                name = "renders buttons one per row with digit prefixes when focused",
                id = "row-n-focused",
                is_focused = true,
                status_pattern = "pending",
                expect_digit_prefix = true,
                post_action = nil,
            },
            {
                name = "keeps button rows when an active update repaints",
                id = "row-n-active-update",
                is_focused = true,
                status_pattern = "in_progress",
                expect_digit_prefix = true,
                post_action = function(id)
                    writer:update_tool_call_block({
                        tool_call_id = id,
                        status = "in_progress",
                        body = { "running" },
                    })
                end,
            },
            {
                name = "keeps button rows on a non-pending status with no post-update",
                id = "row-n-focused-completed",
                is_focused = true,
                status_pattern = "completed",
                expect_digit_prefix = true,
                post_action = function(id)
                    local tracker = writer.tool_call_blocks[id]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    tracker.status = "completed"
                    writer:repaint_status_row(id)
                end,
            },
        }) do
            it(case.name, function()
                setup_permission_block(
                    case.id,
                    { is_focused = case.is_focused }
                )

                if case.post_action then
                    case.post_action(case.id)
                end

                local status_text = status_row_text(case.id)
                assert.truthy(status_text:find(case.status_pattern))
                assert.is_nil(status_text:find("Allow"))
                assert.is_nil(status_text:find("Reject"))

                -- 2 buttons + 1 inter-button spacer + 1 trailing spacer.
                local rows = button_row_lines(case.id)
                assert.equal(4, #rows)
                assert.equal("", rows[2])
                assert.equal("", rows[4])
                assert.truthy(rows[1]:find("Allow"))
                assert.truthy(rows[3]:find("Reject"))
                if case.expect_digit_prefix then
                    assert.truthy(rows[1]:find("^ 1 "))
                    assert.truthy(rows[3]:find("^ 2 "))
                else
                    assert.is_nil(rows[1]:find(" 1 "))
                    assert.is_nil(rows[3]:find(" 2 "))
                end
            end)
        end

        for _, case in ipairs({
            {
                index = 1,
                focused_hl = "AgenticPermissionButtonAllow",
                unfocused_hl = "AgenticPermissionButtonReject",
                label = "allow",
            },
            {
                index = 2,
                focused_hl = "AgenticPermissionButtonReject",
                unfocused_hl = "AgenticPermissionButtonAllow",
                label = "reject",
            },
        }) do
            it(
                "applies "
                    .. case.label
                    .. " hl only on the focused "
                    .. case.label
                    .. " button row (focused_button_index = "
                    .. case.index
                    .. ")",
                function()
                    local id = "row-n-hl-" .. case.label
                    setup_permission_block(id, {
                        is_focused = true,
                        focused_button_index = case.index,
                    })

                    local marks = button_row_marks(id)
                    assert.equal(1, count_hl_marks(marks, case.focused_hl))
                    assert.equal(0, count_hl_marks(marks, case.unfocused_hl))
                    -- The non-focused button stays inactive.
                    assert.equal(
                        1,
                        count_hl_marks(marks, "AgenticPermissionButtonInactive")
                    )
                end
            )
        end

        it(
            "applies inactive highlight group on every button row when not focused",
            function()
                setup_permission_block(
                    "row-n-hl-inactive",
                    { is_focused = false }
                )

                local marks = button_row_marks("row-n-hl-inactive")
                assert.equal(
                    2,
                    count_hl_marks(marks, "AgenticPermissionButtonInactive")
                )
            end
        )

        it("button labels are not wrapped in square brackets", function()
            setup_permission_block("row-n-nobracket", {
                sorted_options = { ALLOW_REJECT_OPTIONS[1] },
                is_focused = true,
                focused_button_index = 1,
            })

            -- 1 button + 1 trailing spacer.
            local rows = button_row_lines("row-n-nobracket")
            assert.equal(2, #rows)
            assert.equal("", rows[2])
            assert.is_nil(rows[1]:find("%["))
            assert.is_nil(rows[1]:find("%]"))
            assert.truthy(rows[1]:find("Allow"))
        end)

        describe("_build_permission_section button rows", function()
            --- @param id string
            --- @param state { is_focused: boolean, focused_button_index?: integer, sorted_options?: table[] }
            --- @return agentic.ui.MessageWriter.PermissionSection
            local function build_section(id, state)
                writer:write_tool_call_block(
                    make_tool_call_block(id, "pending")
                )
                writer:set_permission_state(id, {
                    sorted_options = state.sorted_options
                        or ALLOW_REJECT_OPTIONS,
                    is_focused = state.is_focused,
                    focused_button_index = state.focused_button_index,
                })
                local tracker = writer.tool_call_blocks[id]
                --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                return writer:_build_permission_section(tracker)
            end

            it(
                "builds one button line per option without digit prefix when not focused",
                function()
                    local section = build_section("section-non-focused", {
                        is_focused = false,
                    })

                    -- 2 buttons + 2 spacers; pin shape first so a regression
                    -- to N rows surfaces here, not as a nil-index error below.
                    assert.equal(4, #section.button_lines)
                    -- No digit prefix in non-focused state.
                    assert.is_nil(section.button_lines[1]:find(" 1 "))
                    assert.is_nil(section.button_lines[3]:find(" 2 "))
                    assert.truthy(section.button_lines[1]:find("Allow once"))
                    assert.truthy(section.button_lines[3]:find("Reject once"))
                end
            )

            it(
                "prefixes each line with the 1-indexed digit when focused",
                function()
                    local section = build_section("section-focused", {
                        is_focused = true,
                        focused_button_index = 1,
                    })

                    -- 2 buttons + 2 spacers; pin shape first so a regression
                    -- to N rows surfaces here, not as a nil-index error below.
                    assert.equal(4, #section.button_lines)
                    -- Padded with leading + trailing space.
                    assert.truthy(section.button_lines[1]:find("^ 1 "))
                    assert.truthy(section.button_lines[3]:find("^ 2 "))
                    assert.truthy(section.button_lines[1]:find("Allow once"))
                    assert.truthy(section.button_lines[3]:find("Reject once"))
                end
            )

            for _, case in ipairs({
                {
                    index = 1,
                    focused_hl = "AgenticPermissionButtonAllow",
                    unfocused_hl = "AgenticPermissionButtonInactive",
                    label = "allow",
                },
                {
                    index = 2,
                    focused_hl = "AgenticPermissionButtonReject",
                    unfocused_hl = "AgenticPermissionButtonInactive",
                    label = "reject",
                },
            }) do
                it(
                    "emits one full-row segment per button line for the focused "
                        .. case.label
                        .. " button",
                    function()
                        local section =
                            build_section("section-hl-" .. case.label, {
                                is_focused = true,
                                focused_button_index = case.index,
                            })

                        -- 2 buttons + 2 spacers (between + trailing).
                        assert.equal(4, #section.button_segments_per_line)
                        -- Spacers at indices 2 and 4 have no segments.
                        assert.equal(0, #section.button_segments_per_line[2])
                        assert.equal(0, #section.button_segments_per_line[4])

                        for _, i in ipairs({ 1, 3 }) do
                            local segs = section.button_segments_per_line[i]
                            local line = section.button_lines[i]
                            assert.equal(1, #segs)
                            assert.equal(0, segs[1][1])
                            assert.equal(#line, segs[1][2])
                        end

                        -- Button index 1 -> line 1; button index 2 -> line 3.
                        local focused_line_idx = case.index == 1 and 1 or 3
                        local other_line_idx = case.index == 1 and 3 or 1

                        local focused_seg =
                            section.button_segments_per_line[focused_line_idx][1]
                        assert.equal(case.focused_hl, focused_seg[3])

                        local other_seg =
                            section.button_segments_per_line[other_line_idx][1]
                        assert.equal(case.unfocused_hl, other_seg[3])
                    end
                )
            end

            it(
                "uses the inactive hl group on every button line when not focused",
                function()
                    local section = build_section("section-hl-inactive", {
                        is_focused = false,
                    })

                    -- 2 buttons + 2 spacers (between + trailing).
                    assert.equal(4, #section.button_segments_per_line)
                    -- Spacers at indices 2 and 4 have no segments.
                    assert.equal(0, #section.button_segments_per_line[2])
                    assert.equal(0, #section.button_segments_per_line[4])

                    for _, i in ipairs({ 1, 3 }) do
                        local segs = section.button_segments_per_line[i]
                        assert.equal(1, #segs)
                        assert.equal(
                            "AgenticPermissionButtonInactive",
                            segs[1][3]
                        )
                    end
                end
            )

            for _, case in ipairs({
                {
                    name = "writes the provider option.name verbatim on the button line",
                    id = "section-long-label",
                    option_name = "Yes, and bypass permissions for this session",
                    option_kind = "allow_always",
                    option_id = "allow-always",
                    expected_label = "Yes, and bypass permissions for this session",
                },
                {
                    name = "falls back to the static label when option.name is nil",
                    id = "section-fallback-nil",
                    option_name = nil,
                    option_kind = "allow_always",
                    option_id = "allow-always",
                    expected_label = "Allow Always",
                },
                {
                    name = "falls back to the static label when option.name is empty",
                    id = "section-fallback-empty",
                    option_name = "",
                    option_kind = "reject_always",
                    option_id = "reject-always",
                    expected_label = "Reject Always",
                },
            }) do
                it(case.name, function()
                    local section = build_section(case.id, {
                        sorted_options = {
                            {
                                optionId = case.option_id,
                                name = case.option_name,
                                kind = case.option_kind,
                            },
                        },
                        is_focused = false,
                    })

                    -- 1 button + 1 trailing spacer.
                    assert.equal(2, #section.button_lines)
                    assert.equal("", section.button_lines[2])
                    assert.truthy(
                        section.button_lines[1]:find(
                            case.expected_label,
                            1,
                            true
                        )
                    )
                end)
            end

            it(
                "produces one button line and a trailing spacer for a single option",
                function()
                    local section = build_section("section-single", {
                        sorted_options = { ALLOW_REJECT_OPTIONS[1] },
                        is_focused = false,
                    })

                    -- 1 button + 1 trailing spacer.
                    assert.equal(2, #section.button_lines)
                    assert.equal(2, #section.button_segments_per_line)
                    assert.equal("", section.button_lines[2])
                    assert.equal(0, #section.button_segments_per_line[2])
                end
            )

            it(
                "produces one button line per option for four options",
                function()
                    local section = build_section("section-four", {
                        sorted_options = {
                            {
                                optionId = "allow-once",
                                name = "Allow",
                                kind = "allow_once",
                            },
                            {
                                optionId = "allow-always",
                                name = "Allow Always",
                                kind = "allow_always",
                            },
                            {
                                optionId = "reject-once",
                                name = "Reject",
                                kind = "reject_once",
                            },
                            {
                                optionId = "reject-always",
                                name = "Reject Always",
                                kind = "reject_always",
                            },
                        },
                        is_focused = true,
                        focused_button_index = 3,
                    })

                    -- 4 buttons + 4 spacers (between each pair + trailing).
                    assert.equal(8, #section.button_lines)
                    assert.equal(8, #section.button_segments_per_line)
                    -- Buttons at indices 1, 3, 5, 7; spacers at 2, 4, 6, 8.
                    for i = 1, 4 do
                        local line_idx = (i - 1) * 2 + 1
                        assert.truthy(
                            section.button_lines[line_idx]:find(
                                "^ " .. i .. " "
                            )
                        )
                    end
                    for _, spacer_idx in ipairs({ 2, 4, 6, 8 }) do
                        assert.equal("", section.button_lines[spacer_idx])
                    end
                end
            )

            it(
                "uses an empty icon when permission_icons config is empty",
                function()
                    local original = Config.permission_icons
                    --- @diagnostic disable-next-line: missing-fields
                    Config.permission_icons = {}

                    -- Restore on any error so a failing build_section does
                    -- not leak the empty config into later tests.
                    local ok, section =
                        pcall(build_section, "section-empty-icons", {
                            sorted_options = { ALLOW_REJECT_OPTIONS[1] },
                            is_focused = false,
                        })

                    Config.permission_icons = original

                    assert.is_true(ok)
                    -- 1 button + 1 trailing spacer.
                    assert.equal(2, #section.button_lines)
                    -- No icon: label sits between leading + trailing space.
                    assert.truthy(
                        section.button_lines[1]:find("Allow once", 1, true)
                    )
                    assert.is_nil(section.button_lines[1]:match("[^%s%w]"))
                    assert.equal("", section.button_lines[2])
                end
            )

            it(
                "carries the status word in status_text and excludes button text",
                function()
                    local section = build_section("section-status-text", {
                        is_focused = false,
                    })

                    assert.truthy(section.status_text:find("pending"))
                    assert.is_nil(
                        section.status_text:find("Allow once", 1, true)
                    )
                    assert.is_nil(
                        section.status_text:find("Reject once", 1, true)
                    )
                end
            )

            -- Task 3: render path + repaint_status_row wiring.

            it(
                "inserts K button rows between bottom_pad and the status row on first paint",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("render-first-paint", "pending")
                    )
                    local end_row_before = block_end_row("render-first-paint")

                    writer:set_permission_state("render-first-paint", {
                        sorted_options = ALLOW_REJECT_OPTIONS,
                        is_focused = false,
                    })
                    writer:repaint_status_row("render-first-paint")

                    local tracker =
                        writer.tool_call_blocks["render-first-paint"]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    -- 2 buttons + 2 spacers (between + trailing).
                    assert.equal(4, tracker._rendered_button_count)

                    local end_row_after = block_end_row("render-first-paint")
                    assert.equal(end_row_before + 4, end_row_after)

                    local lines = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row_after - 4,
                        end_row_after + 1,
                        false
                    )
                    assert.equal(5, #lines)
                    assert.truthy(lines[1]:find("Allow"))
                    assert.equal("", lines[2])
                    assert.truthy(lines[3]:find("Reject"))
                    assert.equal("", lines[4])
                    assert.truthy(lines[5]:find("pending"))
                end
            )

            it(
                "renders status row with status word only and one NS_STATUS extmark per row",
                function()
                    setup_permission_block("render-extmarks", {
                        is_focused = false,
                    })

                    local end_row = block_end_row("render-extmarks")
                    local tracker = writer.tool_call_blocks["render-extmarks"]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    local k = tracker._rendered_button_count
                    -- 2 buttons + 2 spacers (between + trailing).
                    assert.equal(4, k)

                    local status_text = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row,
                        end_row + 1,
                        false
                    )[1]
                    assert.truthy(status_text:find("pending"))
                    assert.is_nil(status_text:find("Allow"))
                    assert.is_nil(status_text:find("Reject"))

                    local ns =
                        vim.api.nvim_create_namespace("agentic_status_footer")
                    local marks_on_status = vim.api.nvim_buf_get_extmarks(
                        bufnr,
                        ns,
                        { end_row, 0 },
                        { end_row, -1 },
                        { details = true }
                    )
                    assert.equal(1, #marks_on_status)

                    local first_btn_row = end_row - k
                    -- Button rows at offsets 0 and 2 (1 is the spacer).
                    for _, offset in ipairs({ 0, 2 }) do
                        local btn_row = first_btn_row + offset
                        local marks = vim.api.nvim_buf_get_extmarks(
                            bufnr,
                            ns,
                            { btn_row, 0 },
                            { btn_row, -1 },
                            { details = true }
                        )
                        assert.equal(1, #marks)
                    end
                end
            )

            it(
                "extmark end_row grows by K on permission render (end_right_gravity regression)",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("render-gravity", "pending")
                    )
                    local before = block_end_row("render-gravity")

                    writer:set_permission_state("render-gravity", {
                        sorted_options = ALLOW_REJECT_OPTIONS,
                        is_focused = false,
                    })
                    writer:repaint_status_row("render-gravity")

                    local after = block_end_row("render-gravity")
                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer.
                    assert.equal(before + 4, after)

                    -- end_row must be the new status row (the last line of the block).
                    local lines = vim.api.nvim_buf_get_lines(
                        bufnr,
                        after,
                        after + 1,
                        false
                    )
                    assert.truthy(lines[1]:find("pending"))
                end
            )

            it(
                "rewrites button rows with digit prefix on switch to focused",
                function()
                    setup_permission_block("render-focus-switch", {
                        is_focused = false,
                    })

                    local end_row = block_end_row("render-focus-switch")
                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer:
                    -- buttons at -4 and -2, spacers at -3 and -1.
                    local rows_before = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row - 4,
                        end_row,
                        false
                    )
                    assert.is_nil(rows_before[1]:find(" 1 "))
                    assert.equal("", rows_before[2])
                    assert.is_nil(rows_before[3]:find(" 2 "))
                    assert.equal("", rows_before[4])

                    writer:set_permission_state("render-focus-switch", {
                        sorted_options = ALLOW_REJECT_OPTIONS,
                        is_focused = true,
                        focused_button_index = 1,
                    })
                    writer:repaint_status_row("render-focus-switch")

                    end_row = block_end_row("render-focus-switch")
                    local rows_after = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row - 4,
                        end_row,
                        false
                    )
                    assert.truthy(rows_after[1]:find("^ 1 "))
                    assert.equal("", rows_after[2])
                    assert.truthy(rows_after[3]:find("^ 2 "))
                    assert.equal("", rows_after[4])

                    -- Status row still only has the status word.
                    local status_text = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row,
                        end_row + 1,
                        false
                    )[1]
                    assert.truthy(status_text:find("pending"))
                    assert.is_nil(status_text:find("Allow"))
                end
            )

            it(
                "deletes button rows when permission state is cleared and shrinks block",
                function()
                    setup_permission_block("render-clear", {
                        is_focused = true,
                        focused_button_index = 1,
                    })
                    local end_row_with_buttons = block_end_row("render-clear")

                    writer:set_permission_state("render-clear", nil)
                    writer:repaint_status_row("render-clear")

                    local tracker = writer.tool_call_blocks["render-clear"]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    assert.equal(0, tracker._rendered_button_count)

                    local end_row_after = block_end_row("render-clear")
                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer removed.
                    assert.equal(end_row_with_buttons - 4, end_row_after)

                    local status_text = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row_after,
                        end_row_after + 1,
                        false
                    )[1]
                    assert.truthy(status_text:find("pending"))
                    assert.is_nil(status_text:find("Allow"))
                end
            )

            it(
                "is idempotent when repainted twice with the same state",
                function()
                    setup_permission_block("render-idempotent", {
                        is_focused = true,
                        focused_button_index = 1,
                    })

                    local end_row_1 = block_end_row("render-idempotent")
                    local lines_1 = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row_1 - 4,
                        end_row_1 + 1,
                        false
                    )

                    writer:repaint_status_row("render-idempotent")

                    local end_row_2 = block_end_row("render-idempotent")
                    assert.equal(end_row_1, end_row_2)

                    local lines_2 = vim.api.nvim_buf_get_lines(
                        bufnr,
                        end_row_2 - 4,
                        end_row_2 + 1,
                        false
                    )
                    assert.same(lines_1, lines_2)

                    local tracker = writer.tool_call_blocks["render-idempotent"]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer.
                    assert.equal(4, tracker._rendered_button_count)
                end
            )

            it(
                "rendering one block does not displace another block's content",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("render-multi-a", "pending")
                    )
                    writer:write_tool_call_block(
                        make_tool_call_block("render-multi-b", "pending")
                    )

                    local a_end_before = block_end_row("render-multi-a")
                    local b_end_before = block_end_row("render-multi-b")
                    assert.is_true(b_end_before > a_end_before)

                    writer:set_permission_state("render-multi-a", {
                        sorted_options = ALLOW_REJECT_OPTIONS,
                        is_focused = false,
                    })
                    writer:repaint_status_row("render-multi-a")

                    local a_end_after = block_end_row("render-multi-a")
                    local b_end_after = block_end_row("render-multi-b")

                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer.
                    assert.equal(a_end_before + 4, a_end_after)
                    assert.equal(b_end_before + 4, b_end_after)

                    -- Block B unchanged: status row still carries the
                    -- status word and no button text.
                    local b_status = vim.api.nvim_buf_get_lines(
                        bufnr,
                        b_end_after,
                        b_end_after + 1,
                        false
                    )[1]
                    assert.truthy(b_status:find("pending"))
                    assert.is_nil(b_status:find("Allow"))
                end
            )
        end)

        it(
            "clears button rows when permission state is removed and repainted",
            function()
                setup_permission_block("row-n-clear", {
                    sorted_options = { ALLOW_REJECT_OPTIONS[1] },
                    is_focused = true,
                    focused_button_index = 1,
                })

                -- 1 button + 1 trailing spacer.
                local rows_before = button_row_lines("row-n-clear")
                assert.equal(2, #rows_before)
                assert.truthy(rows_before[1]:find("Allow"))
                assert.equal("", rows_before[2])
                local end_row_before = block_end_row("row-n-clear")

                writer:set_permission_state("row-n-clear", nil)
                writer:repaint_status_row("row-n-clear")

                local rows_after = button_row_lines("row-n-clear")
                assert.equal(0, #rows_after)
                local tracker = writer.tool_call_blocks["row-n-clear"]
                --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                assert.equal(0, tracker._rendered_button_count)
                -- Block shrinks back to its pre-permission end_row.
                assert.equal(end_row_before - 2, block_end_row("row-n-clear"))

                local text = status_row_text("row-n-clear")
                assert.is_nil(text:find("Allow"))
                assert.truthy(text:find("pending"))
            end
        )

        describe("_build_permission_section (Task 1 stub)", function()
            it(
                "returns the no-permission shape for a completed block",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("section-completed", "completed")
                    )

                    local tracker = writer.tool_call_blocks["section-completed"]
                    assert.is_not_nil(tracker)
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    local section = writer:_build_permission_section(tracker)

                    assert.is_table(section.button_lines)
                    assert.equal(0, #section.button_lines)
                    assert.is_table(section.button_segments_per_line)
                    assert.equal(0, #section.button_segments_per_line)
                    assert.equal("string", type(section.status_text))
                    assert.truthy(section.status_text:find("completed"))
                    assert.is_table(section.status_segments)
                    assert.is_true(#section.status_segments >= 1)
                end
            )

            it(
                "returns the no-permission shape for a pending block without permission state",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("section-pending", "pending")
                    )

                    local tracker = writer.tool_call_blocks["section-pending"]
                    assert.is_not_nil(tracker)
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    local section = writer:_build_permission_section(tracker)

                    assert.equal(0, #section.button_lines)
                    assert.equal(0, #section.button_segments_per_line)
                    assert.truthy(section.status_text:find("pending"))
                end
            )
        end)

        describe("get_button_row", function()
            it("returns nil when the block has no permission state", function()
                writer:write_tool_call_block(
                    make_tool_call_block("get-row-no-perm", "pending")
                )

                assert.is_nil(writer:get_button_row("get-row-no-perm", 1))
            end)

            it(
                "returns nil when permission state exists but nothing rendered yet",
                function()
                    writer:write_tool_call_block(
                        make_tool_call_block("get-row-not-rendered", "pending")
                    )
                    -- Permission state set but no repaint -> k == 0.
                    writer:set_permission_state("get-row-not-rendered", {
                        sorted_options = ALLOW_REJECT_OPTIONS,
                        is_focused = true,
                        focused_button_index = 1,
                    })

                    local tracker =
                        writer.tool_call_blocks["get-row-not-rendered"]
                    --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
                    assert.equal(0, tracker._rendered_button_count)
                    assert.is_nil(
                        writer:get_button_row("get-row-not-rendered", 1)
                    )
                end
            )

            it("returns nil for an unknown tool_call_id", function()
                assert.is_nil(writer:get_button_row("does-not-exist", 1))
            end)

            it(
                "returns the buffer row of each rendered button after repaint",
                function()
                    setup_permission_block(
                        "get-row-two-options",
                        { is_focused = true }
                    )

                    local end_row = block_end_row("get-row-two-options")
                    --- @cast end_row integer
                    -- 2 buttons + 1 inter-spacer + 1 trailing spacer = 4 rendered rows.
                    local bottom_pad_row = end_row - 4 - 1

                    -- Button 1 at offset +1; button 2 at offset +3 (spacers
                    -- at +2 and +4).
                    local row_1 =
                        writer:get_button_row("get-row-two-options", 1)
                    local row_2 =
                        writer:get_button_row("get-row-two-options", 2)
                    assert.equal(bottom_pad_row + 1, row_1)
                    assert.equal(bottom_pad_row + 3, row_2)
                    assert.is_nil(
                        writer:get_button_row("get-row-two-options", 3)
                    )
                    assert.is_nil(
                        writer:get_button_row("get-row-two-options", 0)
                    )

                    -- Returned rows must contain actual button text, not a
                    -- spacer; guards against get_button_row math drifting
                    -- from the rendered layout.
                    --- @cast row_1 integer
                    --- @cast row_2 integer
                    local line_1 = vim.api.nvim_buf_get_lines(
                        bufnr,
                        row_1,
                        row_1 + 1,
                        false
                    )[1] or ""
                    local line_2 = vim.api.nvim_buf_get_lines(
                        bufnr,
                        row_2,
                        row_2 + 1,
                        false
                    )[1] or ""
                    assert.truthy(line_1:find("Allow"))
                    assert.truthy(line_2:find("Reject"))
                end
            )
        end)
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        local read_stub
        local path_stub

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
            read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
            path_stub = spy.stub(FileSystem, "to_absolute_path")
            path_stub:invokes(function(path)
                return path
            end)
        end)

        after_each(function()
            read_stub:revert()
            path_stub:revert()
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
        end)

        it(
            "wraps markdown-file diffs in a 5-backtick fence so inner ``` survives",
            function()
                read_stub:returns({ "old line" })

                local Theme = require("agentic.theme")
                local lang = Theme.get_language_from_path("README.md")
                local open_fence = string.rep("`", 5) .. lang
                local close_fence = string.rep("`", 5)

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-md-fence",
                    status = "pending",
                    kind = "edit",
                    argument = "README.md",
                    file_path = "README.md",
                    diff = {
                        old = { "old line" },
                        new = { "new line", "```", "still new" },
                    },
                }

                local lines = writer:_prepare_block_lines(block)

                local open_idx, close_idx, inner_idx
                for i, line in ipairs(lines) do
                    if line == open_fence then
                        open_idx = i
                    elseif line == close_fence and not close_idx then
                        close_idx = i
                    elseif line == "```" then
                        inner_idx = i
                    end
                end

                assert.is_not_nil(open_idx)
                assert.is_not_nil(close_idx)
                assert.is_not_nil(inner_idx)
                assert.is_true(open_idx < inner_idx)
                assert.is_true(inner_idx < close_idx)
            end
        )
    end)

    describe("tool call title truncation", function()
        before_each(function()
            Config.tool_calls = {
                title = {
                    max_length = 50,
                    truncate_title_kinds = {
                        "execute",
                        "think",
                        "SubAgent",
                        "fetch",
                        "search",
                    },
                },
            }
        end)

        --- @param kind agentic.acp.ToolKind
        --- @param argument string
        --- @return agentic.ui.MessageWriter.ToolCallBlock block
        local function make_title_block(kind, argument)
            return {
                tool_call_id = "title-" .. kind,
                status = "completed",
                kind = kind,
                argument = argument,
                body = { "output" },
            }
        end

        it(
            "truncates selected long titles and renders full title body",
            function()
                local title = string.rep("x", 55) .. "\\nsecond line"

                writer:write_tool_call_block(make_title_block("execute", title))

                local content = get_all_content()
                assert.truthy(
                    content:find(
                        "execute(" .. string.rep("x", 50) .. "...)",
                        1,
                        true
                    )
                )
                assert.truthy(content:find("`````bash", 1, true))
                assert.truthy(content:find(string.rep("x", 55), 1, true))
                assert.truthy(content:find("second line", 1, true))
                assert.truthy(content:find("`````\n\n---\n\noutput", 1, true))
                assert.is_false(
                    line_has_comment_highlight(TITLE_FENCE .. "bash")
                )
                assert.is_false(line_has_comment_highlight(string.rep("x", 55)))
                assert.is_false(line_has_comment_highlight("second line"))
                assert.is_false(line_has_comment_highlight(TITLE_FENCE))
                assert.is_false(line_has_comment_highlight("---"))
                assert.is_true(line_has_comment_highlight("output"))
                assert.same(
                    { "output" },
                    writer.tool_call_blocks["title-execute"].body
                )
            end
        )

        it("keeps selected short titles in the header only", function()
            writer:write_tool_call_block(make_title_block("execute", "ls"))

            local content = get_all_content()
            assert.truthy(content:find(" execute(ls) ", 1, true))
            assert.is_nil(content:find("`````bash", 1, true))
        end)

        it("does not truncate non-selected long titles", function()
            local title = string.rep("x", 55)

            writer:write_tool_call_block(make_title_block("write", title))

            local content = get_all_content()
            assert.truthy(content:find(" write(" .. title .. ") ", 1, true))
            assert.is_nil(
                content:find("write(" .. string.rep("x", 50) .. "...)", 1, true)
            )
            assert.is_nil(content:find("`````", 1, true))
        end)

        it("re-renders late long titles without mutating body", function()
            writer:write_tool_call_block(make_title_block("execute", "bash"))

            local late_title = "ls " .. string.rep("x", 60)
            writer:update_tool_call_block({
                tool_call_id = "title-execute",
                argument = late_title,
            })

            local content = get_all_content()
            assert.truthy(
                content:find(
                    "execute(" .. late_title:sub(1, 50) .. "...)",
                    1,
                    true
                )
            )
            assert.truthy(content:find("`````bash", 1, true))
            assert.truthy(content:find(late_title, 1, true))
            assert.same(
                { "output" },
                writer.tool_call_blocks["title-execute"].body
            )
        end)

        it("uses text fences for non-execute selected kinds", function()
            local title = string.rep("x", 55)

            writer:write_tool_call_block(make_title_block("SubAgent", title))

            local content = get_all_content()
            assert.truthy(content:find("`````text", 1, true))
            assert.is_nil(content:find("`````bash", 1, true))
        end)
    end)

    describe("sender header tracking", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("writes user header on first user_message_chunk", function()
            writer:write_message_chunk(
                make_update("hello", "user_message_chunk")
            )

            assert.equal(
                1,
                count_matching_lines("^## .* User %- %d%d%d%d%-%d%d%-%d%d")
            )
        end)

        it("writes agent header on first agent_message_chunk", function()
            writer:set_provider_name("TestAgent")
            writer:write_message_chunk(
                make_update("response", "agent_message_chunk")
            )

            assert.equal(1, count_matching_lines("### .* Agent %- TestAgent"))
        end)

        it("skips header for consecutive same sender", function()
            writer:write_message_chunk(
                make_update("msg1", "user_message_chunk")
            )
            writer:write_message_chunk(
                make_update("msg2", "user_message_chunk")
            )

            assert.equal(1, count_matching_lines("^## .* User"))
        end)

        it("writes agent header before tool call block", function()
            writer:set_provider_name("TestAgent")
            writer:write_message_chunk(
                make_update("question", "user_message_chunk")
            )
            writer:write_tool_call_block(
                make_tool_call_block("tc-1", "pending")
            )

            local lines = get_all_lines()
            local user_idx, agent_idx
            for i, line in ipairs(lines) do
                if line:match("^## .* User") then
                    user_idx = i
                end
                if line:match("### .* Agent %- TestAgent") then
                    agent_idx = i
                end
            end
            assert.is_not_nil(user_idx)
            assert.is_not_nil(agent_idx)
            assert.is_true(agent_idx > user_idx)
        end)

        it("omits timestamp when restoring", function()
            writer:write_restoring_message(
                make_update("restored", "user_message_chunk")
            )

            assert.equal(1, count_matching_lines("^## .* User$"))
            assert.equal(0, count_matching_lines("^## .* User %- %d%d%d%d"))
        end)

        it("skips header for plan updates", function()
            writer:_maybe_write_sender_header("plan")

            assert.equal(0, count_matching_lines("Agent"))
            assert.equal(0, count_matching_lines("User"))
        end)

        it(
            "writes agent header for thought chunk if last sender was user",
            function()
                writer:set_provider_name("TestAgent")
                writer:write_message_chunk(
                    make_update("question", "user_message_chunk")
                )
                writer:write_message_chunk(
                    make_update("thinking...", "agent_thought_chunk")
                )

                assert.equal(
                    1,
                    count_matching_lines("### .* Agent %- TestAgent")
                )
            end
        )
    end)

    describe("replay_history_messages", function()
        it("replays messages with correct provider-specific headers", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "user",
                    text = "hello",
                    timestamp = 1000,
                    provider_name = "Claude",
                },
                {
                    type = "agent",
                    text = "from claude",
                    provider_name = "Claude",
                },
                {
                    type = "user",
                    text = "another question",
                    provider_name = "Claude",
                },
                {
                    type = "agent",
                    text = "from gemini",
                    provider_name = "Gemini",
                },
            }

            writer:replay_history_messages(messages)

            local content = get_all_content()
            assert.truthy(content:match("## .* User"))
            assert.truthy(content:match("hello"))
            assert.truthy(content:match("### .* Agent %- Claude"))
            assert.truthy(content:match("from claude"))
            assert.truthy(content:match("### .* Agent %- Gemini"))
            assert.truthy(content:match("from gemini"))
        end)

        it("restores current provider after replay", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "agent",
                    text = "old message",
                    provider_name = "Gemini",
                },
            }

            writer:replay_history_messages(messages)

            assert.equal("Claude", writer._provider_name)
        end)

        it("handles thought chunk messages with highlighting", function()
            writer:set_provider_name("Claude")

            writer:replay_history_messages({
                {
                    type = "thought",
                    text = "thinking about this",
                    provider_name = "Claude",
                },
            })

            assert.is_true(content_has("🧠 thinking about this"))

            local extmarks = get_thinking_extmarks()
            assert.equal(1, #extmarks)
            local details = extmarks[1][4] --- @type table
            assert.equal("AgenticThinking", details.hl_group)
            assert.is_true(details.hl_eol)
            assert.is_true(details.end_col > 0)
        end)

        it("handles tool_call messages", function()
            writer:set_provider_name("Claude")

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "tool_call",
                    tool_call_id = "tc-1",
                    kind = "read",
                    file_path = "test.txt",
                    status = "completed",
                    body = { "file content" },
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            assert.is_not_nil(writer.tool_call_blocks["tc-1"])
            assert.truthy(get_all_content():match("read"))
        end)

        it("formats unformatted single-line JSON body on replay", function()
            writer:set_provider_name("Claude")

            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "tool_call",
                    tool_call_id = "tc-json",
                    kind = "fetch",
                    argument = "MCP",
                    status = "completed",
                    body = { json_text },
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            local tracker = writer.tool_call_blocks["tc-json"]
            assert.is_not_nil(tracker)
            assert.is_true(#tracker.body > 1)
        end)

        it("renders truncated title body on replay", function()
            Config.tool_calls = {
                title = {
                    max_length = 50,
                    truncate_title_kinds = { "fetch" },
                },
            }
            writer:set_provider_name("Claude")

            local title = string.rep("x", 55)

            --- @type agentic.ui.ChatHistory.Message[]
            local messages = {
                {
                    type = "tool_call",
                    tool_call_id = "tc-title-replay",
                    kind = "fetch",
                    argument = title,
                    status = "completed",
                    body = { "output" },
                    provider_name = "Claude",
                },
            }

            writer:replay_history_messages(messages)

            local content = get_all_content()
            assert.truthy(
                content:find("fetch(" .. string.rep("x", 50) .. "...)", 1, true)
            )
            assert.truthy(content:find("`````text", 1, true))
            assert.truthy(content:find(title, 1, true))
        end)

        it(
            "replay thought extmark covers content lines, not trailing blank",
            function()
                writer:replay_history_messages({
                    {
                        type = "thought",
                        text = "line one\nline two",
                        provider_name = "Claude",
                    },
                })

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local start_row = extmarks[1][2]
                local details = extmarks[1][4] --- @type table
                local end_row = details.end_row

                local start_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    start_row,
                    start_row + 1,
                    false
                )[1]
                assert.truthy(start_line_text:find("🧠"))

                local end_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    end_row,
                    end_row + 1,
                    false
                )[1]
                assert.truthy(end_line_text:find("line two"))

                assert.equal(#end_line_text, details.end_col)
            end
        )
    end)

    describe("thinking block highlighting", function()
        it(
            "creates extmark with correct properties on first thought chunk",
            function()
                writer:write_message_chunk(make_thought_update("thinking"))

                assert.is_not_nil(writer._thinking_extmark_id)
                assert.is_not_nil(writer._thinking_start_line)

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local details = extmarks[1][4] --- @type table
                assert.equal("AgenticThinking", details.hl_group)
                assert.is_true(details.hl_eol)
                assert.is_true(details.end_col > 0)

                assert.is_true(content_has("🧠 thinking"))
            end
        )

        it("does not prepend emoji on subsequent thought chunks", function()
            writer:write_message_chunk(make_thought_update("first"))
            writer:write_message_chunk(make_thought_update(" second"))

            assert.equal(1, count_matching_lines("🧠"))
        end)

        it("updates extmark end_row and end_col as content grows", function()
            writer:write_message_chunk(make_thought_update("line1"))
            local initial_end = writer._thinking_end_line

            writer:write_message_chunk(make_thought_update("\nline2"))
            assert.is_true(writer._thinking_end_line > initial_end)

            local extmarks = get_thinking_extmarks()
            assert.equal(1, #extmarks)
            assert.equal(writer._thinking_end_line, extmarks[1][4].end_row)

            writer._thinking_extmark_id = nil
            writer._thinking_start_line = nil
            writer._thinking_end_line = nil
            writer._scroll_scheduled = false

            writer:write_message_chunk(make_thought_update("start"))
            local before = get_thinking_extmarks()
            local end_col_before = before[2][4].end_col

            writer:write_message_chunk(make_thought_update(" more text"))
            local after = get_thinking_extmarks()
            local end_col_after = after[2][4].end_col

            assert.is_true(end_col_after > end_col_before)
        end)

        it("stops updating extmark when switching to message", function()
            writer:write_message_chunk(make_thought_update("thinking"))
            assert.is_not_nil(writer._thinking_extmark_id)

            writer:write_message_chunk(make_update("response"))

            assert.is_nil(writer._thinking_extmark_id)
            assert.equal(1, #get_thinking_extmarks())
        end)

        it(
            "starts extmark at thought content line, not blank separator after header",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "question" },
                })

                writer:write_message_chunk(make_thought_update("deep thinking"))

                local extmarks = get_thinking_extmarks()
                assert.equal(1, #extmarks)
                local start_row = extmarks[1][2]

                local start_line_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    start_row,
                    start_row + 1,
                    false
                )[1]
                assert.truthy(start_line_text:find("🧠"))
            end
        )

        it(
            "clears thinking state on reset_sender_tracking, write_tool_call_block, and write_message",
            function()
                local triggers = {
                    function()
                        writer:reset_sender_tracking()
                    end,
                    function()
                        writer:write_tool_call_block(
                            make_tool_call_block("tc-clear-1", "pending")
                        )
                    end,
                    function()
                        writer:write_message(make_update("full response"))
                    end,
                }

                for _, trigger in ipairs(triggers) do
                    writer:write_message_chunk(
                        make_thought_update("thinking...")
                    )
                    assert.is_not_nil(writer._thinking_extmark_id)

                    trigger()

                    assert.is_nil(writer._thinking_extmark_id)
                    assert.is_nil(writer._thinking_start_line)
                    assert.is_nil(writer._thinking_end_line)
                end
            end
        )

        it("creates a new extmark for thought after tool call block", function()
            writer:write_message_chunk(make_thought_update("first thought"))
            local first_extmark_id = writer._thinking_extmark_id
            assert.is_not_nil(first_extmark_id)

            writer:write_tool_call_block(
                make_tool_call_block("tc-between-1", "pending")
            )
            writer:write_message_chunk(make_thought_update("second thought"))

            assert.is_not_nil(writer._thinking_extmark_id)
            assert.is_true(writer._thinking_extmark_id ~= first_extmark_id)

            local ns = vim.api.nvim_create_namespace("agentic_thinking")
            local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
            assert.equal(2, #extmarks)
        end)
    end)

    describe("tool call body JSON formatting", function()
        it("formats single-line JSON body when writing the block", function()
            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            local block =
                make_tool_call_block("json-1", "completed", { json_text })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-1"]
            assert.is_not_nil(tracker)
            assert.is_true(#tracker.body > 1)
        end)

        it(
            "leaves placeholder text untouched and formats only JSON segments on update",
            function()
                local placeholder = "I'm going to fetch this"
                local long_value = string.rep("v", 100)
                local json_text = '{"key":"' .. long_value .. '","x":42}'

                local block = make_tool_call_block(
                    "json-stream",
                    "in_progress",
                    { placeholder }
                )
                writer:write_tool_call_block(block)

                writer:update_tool_call_block({
                    tool_call_id = "json-stream",
                    status = "completed",
                    body = { json_text },
                })

                local tracker = writer.tool_call_blocks["json-stream"]
                assert.is_not_nil(tracker)
                assert.equal(placeholder, tracker.body[1])

                local separator_idx
                for i, line in ipairs(tracker.body) do
                    if line == "---" then
                        separator_idx = i
                        break
                    end
                end
                assert.is_not_nil(separator_idx)
                assert.is_true(#tracker.body - separator_idx > 1)
            end
        )

        it("leaves malformed JSON unchanged", function()
            local malformed = "{" .. string.rep("not valid json ", 10) .. "}"

            local block =
                make_tool_call_block("json-bad", "completed", { malformed })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-bad"]
            assert.same({ malformed }, tracker.body)
        end)
    end)

    describe("tool call block update highlighting", function()
        it("comments provider body when writing non-diff tool calls", function()
            writer:write_tool_call_block({
                tool_call_id = "write-hl-1",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = { "write output" },
            })

            assert.is_true(line_has_comment_highlight("write output"))
        end)

        it("comments provider body during non-diff updates", function()
            local block = make_tool_call_block("sync-hl-1", "pending")
            writer:write_tool_call_block(block)

            writer:update_tool_call_block({
                tool_call_id = "sync-hl-1",
                status = "completed",
                body = { "new output" },
            })

            assert.is_true(line_has_comment_highlight("new output"))
        end)

        it("does not comment edit or switch_mode provider bodies", function()
            for _, kind in ipairs({ "edit", "switch_mode" }) do
                writer:write_tool_call_block({
                    tool_call_id = "excluded-" .. kind,
                    status = "completed",
                    kind = kind,
                    argument = kind,
                    body = { kind .. " output" },
                })

                assert.is_false(line_has_comment_highlight(kind .. " output"))
            end
        end)
    end)

    describe("Fold integration", function()
        local Fold = require("agentic.ui.tool_call_fold")
        --- @type agentic.UserConfig.Folding|nil
        local saved_folding

        local LONG_BODY =
            { "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L10" }

        before_each(function()
            saved_folding = Config.folding
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    threshold = 5,
                    fold_on_error = false,
                },
            }
            Config.auto_scroll = { threshold = 10 }

            Fold.setup_window(winid, bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "intro" })
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })
        end)

        after_each(function()
            Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        end)

        --- Read the buffer rows for a block and return its layout slots.
        --- @param tool_call_id string
        --- @return integer start_row, integer top_pad_row, integer bottom_pad_row, integer end_row
        local function block_layout(tool_call_id)
            local tracker = writer.tool_call_blocks[tool_call_id]
            local NS = vim.api.nvim_create_namespace("agentic_tool_blocks")
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                NS,
                tracker.extmark_id,
                { details = true }
            )
            local start_row = pos[1]
            --- @type integer
            local end_row = pos[3].end_row
            return start_row, start_row + 1, end_row - 1, end_row
        end

        --- @param tool_call_id string
        local function assert_fold_closed(tool_call_id)
            local _, top_pad_row, bottom_pad_row = block_layout(tool_call_id)
            vim.api.nvim_win_call(winid, function()
                assert.equal(
                    vim.fn.foldclosed(top_pad_row + 1),
                    top_pad_row + 1
                )
                assert.equal(
                    vim.fn.foldclosedend(top_pad_row + 1),
                    bottom_pad_row + 1
                )
            end)
            assert.is_true(
                writer.tool_call_blocks[tool_call_id].has_fold == true
            )
        end

        --- @param tool_call_id string
        local function assert_fold_open(tool_call_id)
            local _, top_pad_row = block_layout(tool_call_id)
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(top_pad_row + 1), -1)
            end)
            assert.is_nil(writer.tool_call_blocks[tool_call_id].has_fold)
        end

        it(
            "closes a manual fold when completed update crosses the fold threshold",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "fold-mat",
                    status = "pending",
                    kind = "execute",
                    argument = "ls",
                    body = { "short" },
                })

                local _, top_pad_row = block_layout("fold-mat")
                vim.api.nvim_win_call(winid, function()
                    assert.equal(vim.fn.foldclosed(top_pad_row + 1), -1)
                end)

                writer:update_tool_call_block({
                    tool_call_id = "fold-mat",
                    status = "completed",
                    body = LONG_BODY,
                })

                assert_fold_closed("fold-mat")
            end
        )

        it(
            "closes a manual fold when completed write crosses the fold threshold",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "fold-on-write",
                    status = "completed",
                    kind = "execute",
                    argument = "ls",
                    body = LONG_BODY,
                })

                assert_fold_closed("fold-on-write")
            end
        )

        it("keeps active tool calls open when they exceed threshold", function()
            for _, status in ipairs({ "pending", "in_progress" }) do
                local tool_call_id = "open-" .. status
                writer:write_tool_call_block({
                    tool_call_id = tool_call_id,
                    status = status,
                    kind = "execute",
                    argument = "ls",
                    body = LONG_BODY,
                })

                assert_fold_open(tool_call_id)
            end
        end)

        it("keeps active updates open when they exceed threshold", function()
            for _, status in ipairs({ "pending", "in_progress" }) do
                local tool_call_id = "open-update-" .. status
                writer:write_tool_call_block({
                    tool_call_id = tool_call_id,
                    status = "pending",
                    kind = "execute",
                    argument = "ls",
                    body = { "short" },
                })

                writer:update_tool_call_block({
                    tool_call_id = tool_call_id,
                    status = status,
                    body = LONG_BODY,
                })

                assert_fold_open(tool_call_id)
            end
        end)

        it("keeps failed updates open by default", function()
            writer:write_tool_call_block({
                tool_call_id = "failed-open",
                status = "pending",
                kind = "execute",
                argument = "ls",
                body = { "short" },
            })

            writer:update_tool_call_block({
                tool_call_id = "failed-open",
                status = "failed",
                body = LONG_BODY,
            })

            assert_fold_open("failed-open")
        end)

        it("folds failed updates when fold_on_error is enabled", function()
            Config.folding.tool_calls.fold_on_error = true

            writer:write_tool_call_block({
                tool_call_id = "failed-folded",
                status = "pending",
                kind = "execute",
                argument = "ls",
                body = { "short" },
            })

            writer:update_tool_call_block({
                tool_call_id = "failed-folded",
                status = "failed",
                body = LONG_BODY,
            })

            assert_fold_closed("failed-folded")
        end)

        it("folds restored completed tool calls", function()
            writer:replay_history_messages({
                {
                    type = "tool_call",
                    tool_call_id = "restored-completed",
                    status = "completed",
                    kind = "execute",
                    argument = "ls",
                    body = LONG_BODY,
                },
            })

            assert_fold_closed("restored-completed")
        end)

        it("keeps restored failed tool calls open by default", function()
            writer:replay_history_messages({
                {
                    type = "tool_call",
                    tool_call_id = "restored-failed",
                    status = "failed",
                    kind = "execute",
                    argument = "ls",
                    body = LONG_BODY,
                },
            })

            assert_fold_open("restored-failed")
        end)

        it(
            "folds restored failed tool calls when fold_on_error is enabled",
            function()
                Config.folding.tool_calls.fold_on_error = true

                writer:replay_history_messages({
                    {
                        type = "tool_call",
                        tool_call_id = "restored-failed-folded",
                        status = "failed",
                        kind = "execute",
                        argument = "ls",
                        body = LONG_BODY,
                    },
                })

                assert_fold_closed("restored-failed-folded")
            end
        )

        it("does not create a fold when block stays below threshold", function()
            writer:write_tool_call_block({
                tool_call_id = "no-fold",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = { "L1", "L2", "L3" },
            })

            local tracker = writer.tool_call_blocks["no-fold"]
            assert.is_nil(tracker.has_fold)

            local _, top_pad_row = block_layout("no-fold")
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(top_pad_row + 1), -1)
            end)
        end)

        it("counts rendered long title body toward fold threshold", function()
            Config.tool_calls = {
                title = {
                    max_length = 50,
                    truncate_title_kinds = { "execute" },
                },
            }

            writer:write_tool_call_block({
                tool_call_id = "fold-title",
                status = "completed",
                kind = "execute",
                argument = table.concat({
                    string.rep("x", 55),
                    "line two",
                    "line three",
                    "line four",
                    "line five",
                }, "\\n"),
                body = { "short" },
            })

            assert_fold_closed("fold-title")
        end)

        it("emits anchor pad lines around the body in every block", function()
            writer:write_tool_call_block({
                tool_call_id = "anchors",
                status = "pending",
                kind = "execute",
                argument = "ls",
                body = { "B1", "B2" },
            })

            local start_row, top_pad_row, bottom_pad_row, end_row =
                block_layout("anchors")
            local lines =
                vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
            -- Layout: header, top_pad, B1, B2, bottom_pad, trailing
            assert.equal(#lines, 6)
            assert.equal(lines[2], "")
            assert.equal(lines[3], "B1")
            assert.equal(lines[4], "B2")
            assert.equal(lines[5], "")
            assert.equal(top_pad_row, start_row + 1)
            assert.equal(bottom_pad_row, end_row - 1)
        end)
    end)

    describe("_generate_welcome_header", function()
        it(
            "returns header with provider name, session id, and timestamp",
            function()
                local header =
                    writer:generate_welcome_header("Claude ACP", "abc123")

                assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
                assert.truthy(header:match("\n%- %d%d%d%d%-%d%d%-%d%d"))
                assert.truthy(header:match("\n%- session id: abc123\n"))
                assert.truthy(header:match("\n%-%-%- %-%-$"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header = writer:generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.truthy(header:match("\n%- session id: unknown\n"))
            assert.truthy(header:match("\n%-%-%- %-%-$"))
        end)

        it("includes version when provided", function()
            local header =
                writer:generate_welcome_header("Claude ACP", "abc123", "1.2.3")

            assert.truthy(header:match("^# Agentic %- Claude ACP v1%.2%.3\n"))
            assert.truthy(header:match("\n%- session id: abc123\n"))
        end)

        it("omits version when nil", function()
            local header =
                writer:generate_welcome_header("Claude ACP", "abc123", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.is_nil(header:match(" v"))
        end)
    end)

    describe("write_finish_message", function()
        it(
            "writes the error branch with the error icon and inspected err",
            function()
                writer:write_finish_message(
                    nil,
                    { code = -32000, message = "boom" } --[[@as any]]
                )

                assert.truthy(content_has(Config.message_icons.error))
                assert.truthy(content_has("Agent finished with error"))
                assert.truthy(content_has("boom"))
            end
        )

        it("writes the cancelled branch with the stopped icon", function()
            writer:write_finish_message({ stopReason = "cancelled" }, nil)

            assert.truthy(content_has(Config.message_icons.stopped))
            assert.truthy(content_has("Generation stopped by the user request"))
            assert.is_false(content_has(Config.message_icons.error))
            assert.is_false(content_has(Config.message_icons.finished))
        end)

        it("writes the completed branch with the finished icon", function()
            writer:write_finish_message({ stopReason = "end_turn" }, nil)

            assert.truthy(content_has(Config.message_icons.finished))
            assert.is_false(content_has(Config.message_icons.error))
            assert.is_false(content_has(Config.message_icons.stopped))
        end)
    end)
end)
