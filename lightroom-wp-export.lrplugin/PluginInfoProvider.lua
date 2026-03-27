local LrView    = import "LrView"
local LrDialogs = import "LrDialogs"
local LrTasks   = import "LrTasks"
local LrBinding = import "LrBinding"

local logger = import "LrLogger"("WordPressExport")
logger:enable("logfile")

local PluginInfoProvider = {}

function PluginInfoProvider.sectionsForTopOfDialog(f, prefs)
    logger:trace("Building plugin preferences dialog")

    return {
        {
            title = "WordPress Connection",
            synopsis = LrView.bind { key = "wp_connectionStatus", object = prefs },

            f:row {
                f:static_text {
                    title     = "Site URL:",
                    alignment = "right",
                    width     = LrView.share "prefs_label_width",
                },
                f:edit_field {
                    value          = LrView.bind { key = "wp_siteUrl", object = prefs },
                    width_in_chars = 35,
                    tooltip        = "e.g. https://tiags.space",
                },
            },

            f:row {
                f:static_text {
                    title     = "Username:",
                    alignment = "right",
                    width     = LrView.share "prefs_label_width",
                },
                f:edit_field {
                    value          = LrView.bind { key = "wp_username", object = prefs },
                    width_in_chars = 25,
                },
            },

            f:row {
                f:static_text {
                    title     = "App Password:",
                    alignment = "right",
                    width     = LrView.share "prefs_label_width",
                },
                f:edit_field {
                    value          = LrView.bind { key = "wp_appPassword", object = prefs },
                    width_in_chars = 25,
                },
            },

            f:row {
                f:static_text {
                    title     = "",
                    width     = LrView.share "prefs_label_width",
                },
                f:static_text {
                    title           = "Create an Application Password in WordPress: Users \xE2\x86\x92 Profile \xE2\x86\x92 Application Passwords.\nEnter a name (e.g. \"Lightroom\"), click Add New, and paste the generated password above.",
                    fill_horizontal = 1,
                    height_in_lines = 2,
                },
            },

            f:separator { fill_horizontal = 1 },

            f:row {
                f:static_text {
                    title     = "",
                    width     = LrView.share "prefs_label_width",
                },
                f:static_text {
                    title           = "Requirements:\n\xE2\x80\xA2 Your site must use HTTPS (required for Application Passwords)\n\xE2\x80\xA2 The WordPress REST API must be enabled (it is by default)\n\xE2\x80\xA2 Your user account needs permission to create posts and upload media",
                    fill_horizontal = 1,
                    height_in_lines = 4,
                },
            },

            f:row {
                f:push_button {
                    title  = "Test Connection",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            local WordPressAPI = require "WordPressAPI"
                            local Utils        = require "Utils"
                            logger:trace("Testing connection to " .. tostring(prefs.wp_siteUrl))
                            prefs.wp_connectionStatus = "Connecting..."
                            local name, err = WordPressAPI.testConnection(
                                prefs.wp_siteUrl,
                                prefs.wp_username,
                                prefs.wp_appPassword
                            )
                            if name then
                                logger:trace("Connected as: " .. name)
                                prefs.wp_connectionStatus = "Connected as " .. name .. " ✓"

                                local types, typesErr = WordPressAPI.fetchPostTypes(
                                    prefs.wp_siteUrl,
                                    prefs.wp_username,
                                    prefs.wp_appPassword
                                )
                                if types then
                                    logger:trace("Fetched " .. #types .. " post types")
                                    prefs.wp_postTypes = Utils.jsonEncode(types)
                                else
                                    logger:warn("Failed to fetch post types: " .. tostring(typesErr))
                                end
                            else
                                logger:warn("Connection failed: " .. tostring(err))
                                prefs.wp_connectionStatus = "✗ " .. (err or "Unknown error")
                            end
                        end)
                    end,
                },

                f:static_text {
                    title           = LrView.bind { key = "wp_connectionStatus", object = prefs },
                    fill_horizontal = 1,
                },
            },
        },
    }
end

return PluginInfoProvider
