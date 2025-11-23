local GLYPHS = {
    TOP_LEFT = "╭",
    BOTTOM_LEFT = "╰",
    HORIZONTAL = "─",
    VERTICAL = "│",
}

--- @class agentic.utils.ExtmarkBlock
local ExtmarkBlock = {}

--- @class agentic.utils.ExtmarkBlock.RenderBlockOpts
--- @field header_line integer 0-indexed line number for header
--- @field body_start? integer 0-indexed start line for body (optional)
--- @field body_end? integer 0-indexed end line for body (optional)
--- @field footer_line? integer 0-indexed line number for footer (optional)
--- @field hl_group string Highlight group name

--- Renders a complete block with header, optional body, and optional footer
--- @param bufnr integer
--- @param ns_id integer
--- @param opts agentic.utils.ExtmarkBlock.RenderBlockOpts
--- @return integer[]
function ExtmarkBlock.render_block(bufnr, ns_id, opts)
    local decoration_ids = {}

    table.insert(
        decoration_ids,
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, opts.header_line, 0, {
            virt_text = {
                { GLYPHS.TOP_LEFT .. GLYPHS.HORIZONTAL .. " ", opts.hl_group },
            },
            virt_text_pos = "inline",
            hl_mode = "combine",
        })
    )

    -- Add body pipe padding if body exists
    if opts.body_start and opts.body_end then
        for line_num = opts.body_start, opts.body_end do
            table.insert(
                decoration_ids,
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 0, {
                    virt_text = { { GLYPHS.VERTICAL .. " ", opts.hl_group } },
                    virt_text_pos = "inline",
                    hl_mode = "combine",
                })
            )
        end
    end

    if opts.footer_line then
        table.insert(
            decoration_ids,
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, opts.footer_line, 0, {
                virt_text = {
                    {
                        GLYPHS.BOTTOM_LEFT .. GLYPHS.HORIZONTAL .. " ",
                        opts.hl_group,
                    },
                },
                virt_text_pos = "inline",
                hl_mode = "combine",
            })
        )
    end
    return decoration_ids
end

return ExtmarkBlock
