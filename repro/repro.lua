vim.env.LAZY_STDPATH = "../lazy_repro"

load(
    vim.fn.system(
        "curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"
    )
)()

require("lazy.minit").repro({
    spec = {
        {
            name = "agentic.nvim",
            dir = vim.fn.fnamemodify(vim.uv.cwd() or "", ":h"),

            opts = {},

            keys = {
                {
                    "<C-\\>",
                    function()
                        require("agentic").toggle()
                    end,
                    desc = "Agentic Open",
                    silent = true,
                    mode = { "n", "v", "i" },
                },

                {
                    "<C-'>",
                    function()
                        require("agentic").add_selection_or_file_to_context()
                    end,
                    desc = "Agentic Add Selection to context",
                    silent = true,
                    mode = { "n", "v" },
                },

                {
                    "<C-,>",
                    function()
                        require("agentic").new_session()
                    end,
                    desc = "Agentic New Session",
                    silent = true,
                    mode = { "n", "v", "i" },
                },
            },
        },
    },
})
