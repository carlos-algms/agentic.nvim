local configDefault = require("agentic.config_default")

--- @type agentic.UserConfig
local Config = vim.tbl_deep_extend("force", {}, configDefault)

return Config
