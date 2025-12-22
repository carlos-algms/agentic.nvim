#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = "lazy_repro"
load(
    vim.fn.system(
        "curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"
    )
)()

require("lazy.minit").busted({
    spec = {
        {
            name = "agentic.nvim",
            dir = vim.uv.cwd(),
        },
        -- Add any plugin dependencies here if needed
    },
})
