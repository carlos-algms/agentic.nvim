local assert = require("tests.helpers.assert")

-- These tests exist to force LuaLS type checking and Selene linting on
-- PartialUserConfig usage. They are NOT testing runtime config behavior --
-- they validate that the (partial) type annotations allow incomplete
-- nested tables without triggering type errors or lint warnings.
describe("config_default", function()
    describe("agentic.PartialUserConfig type", function()
        it("accepts a partial top-level config without warnings", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                debug = true,
                provider = "claude-agent-acp",
            }

            assert.equal(true, cfg.debug)
            assert.equal("claude-agent-acp", cfg.provider)
        end)

        it("accepts partial nested windows config", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                windows = {
                    width = "50%",
                    position = "left",
                },
            }

            assert.equal("50%", cfg.windows.width)
            assert.equal("left", cfg.windows.position)
        end)

        it("accepts partial nested sub-window config", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                windows = {
                    input = { height = 20 },
                    todos = { display = false },
                },
            }

            assert.equal(20, cfg.windows.input.height)
            assert.equal(false, cfg.windows.todos.display)
        end)

        it("accepts partial icon overrides", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                status_icons = { pending = "?" },
                chat_icons = { user = "U" },
            }

            assert.equal("?", cfg.status_icons.pending)
            assert.equal("U", cfg.chat_icons.user)
        end)

        it("accepts partial keymaps", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                keymaps = {
                    widget = { close = "x" },
                },
            }

            assert.equal("x", cfg.keymaps.widget.close)
        end)

        it("accepts partial diff_preview", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                diff_preview = { enabled = false },
            }

            assert.equal(false, cfg.diff_preview.enabled)
        end)

        it("accepts partial settings", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                settings = { move_cursor_to_chat_on_submit = false },
            }

            assert.equal(false, cfg.settings.move_cursor_to_chat_on_submit)
        end)

        it("accepts an empty config", function()
            --- @type agentic.PartialUserConfig
            local cfg = {}

            assert.is_table(cfg)
        end)
    end)
end)
