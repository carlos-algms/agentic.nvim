local Object = require("agentic.utils.object")
local assert = require("tests.helpers.assert")

describe("object utils", function()
    it("deeply merges 2 objects into the first", function()
        local obj1 = {
            a = 1,
            b = {
                c = 2,
                d = 3,
            },
        }
        local obj2 = {
            b = {
                c = 20,
                e = 30,
            },
            f = 4,
        }

        local expected = {
            a = 1,
            b = {
                c = 20,
                d = 3,
                e = 30,
            },
            f = 4,
        }

        local result = Object.deep_merge_into(obj1, obj2)
        assert.same(expected, result)
    end)

    it(
        "merges config with default config with keymaps overrides instead of merge",
        function()
            --- @type agentic.UserConfig
            local default_config = {
                option1 = true,
                option2 = {
                    suboption1 = 10,
                    suboption2 = 20,
                },
                keymaps = {
                    widget = {
                        close = "q",
                    },
                    prompt = {
                        submit = {
                            "<CR>",
                            {
                                "<C-s>",
                                mode = { "i", "n", "v" },
                            },
                        },

                        paste_image = {
                            {
                                "<localleader>p",
                                mode = { "n", "i" },
                            },
                        },
                    },
                },
            }

            local user_config = {
                option2 = {
                    suboption2 = 200,
                    suboption3 = 300,
                },
                keymaps = {
                    prompt = {
                        submit = {
                            "<TAB>",
                            {
                                "<C-x>",
                                mode = { "n" },
                            },
                        },
                        paste_image = {
                            {
                                "<localleader>x",
                                mode = { "i" },
                            },
                        },
                    },
                },
            }

            local expected_merged_config = {
                option1 = true,
                option2 = {
                    suboption1 = 10,
                    suboption2 = 200,
                    suboption3 = 300,
                },
                keymaps = {
                    widget = {
                        close = "q",
                    },
                    prompt = {
                        submit = {
                            "<TAB>",
                            {
                                "<C-x>",
                                mode = { "n" },
                            },
                        },
                        paste_image = {
                            {
                                "<localleader>x",
                                mode = { "i" },
                            },
                        },
                    },
                },
            }

            local merged_config =
                Object.merge_config(default_config, user_config)

            assert.same(expected_merged_config, merged_config)

            -- Ensure the first object is mutated in place, not a new object created
            assert.is_true(merged_config == default_config)
        end
    )

    describe("handles nil gracefully", function()
        it("handles nil for keymaps", function()
            local default_config = {
                option1 = true,
                keymaps = {
                    widget = {
                        close = "q",
                    },
                },
            }
            local user_config = {
                option1 = false,
                keymaps = nil,
            }

            local expected_merged_config = {
                option1 = false,
                keymaps = {
                    widget = {
                        close = "q",
                    },
                },
            }

            local merged_config =
                Object.merge_config(default_config, user_config)
            assert.same(expected_merged_config, merged_config)
        end)
    end)
end)
