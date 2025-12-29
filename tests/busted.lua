vim.env.LAZY_STDPATH = "lazy_repro"
load(
    vim.fn.system(
        "curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"
    )
)()

local root_dir = vim.uv.cwd()

-- If no arguments provided, default to tests directory
if #arg == 0 then
    table.insert(arg, root_dir .. "/tests")
end

require("lazy.minit").busted({
    spec = {
        {
            name = "agentic.nvim",
            dir = root_dir,
        },
        -- Add any plugin dependencies here if needed
    },
})
