---@diagnostic disable: lowercase-global -- this config file expects globals

cache = true

-- Glorious list of warnings: https://luacheck.readthedocs.io/en/stable/warnings.html
-- Strict mode: only ignore warnings that are truly necessary
ignore = {
    "631", -- Line is too long.
    -- "211", -- Unused variable.
    "212", -- Unused argument, In the case of callback function, _arg_name is easier to understand than _, so this option is set to off.
    -- "411", -- Redefining a local variable.
    -- "412", -- Redefining an argument.
    -- "422", -- Shadowing an argument
    -- "431", -- Shadowing a variable
    -- "122", -- Indirectly setting a readonly global
}

read_globals = {
    "vim",
    "Snacks",
}

globals = {} -- Don't allow any globals beyond read_globals
