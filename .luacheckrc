---@diagnostic disable: lowercase-global, undefined-global -- this config file expects globals

cache = true

exclude_files = {
    "lazy_repro/",
}

-- Glorious list of warnings: https://luacheck.readthedocs.io/en/stable/warnings.html
-- Strict mode: only ignore warnings that are truly necessary
ignore = {
    "631", -- Line is too long.
    -- "211", -- Unused variable.
    "212", -- Unused argument, In the case of callback function, _arg_name is easier to understand than _, so this option is set to off.
    "213", -- Unused loop variable.
    -- "411", -- Redefining a local variable.
    -- "412", -- Redefining an argument.
    -- "422", -- Shadowing an argument
    -- "431", -- Shadowing a variable
    -- "122", -- Indirectly setting a readonly global
}

unused_args = false
unused = false

read_globals = {
    "vim",
    "Snacks",
}

globals = {
    -- Allow setting buffer/window local variables
    "vim.b",
    "vim.bo",
    "vim.wo",
    "vim.opt_local",
    "vim.env", -- Allow setting vim.env in test runner and repro files
}

-- Test files use busted standard
files["**/*_spec.lua"] = {
    std = "+busted",
}