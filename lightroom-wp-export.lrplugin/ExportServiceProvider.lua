local LrView          = import "LrView"
local LrDialogs       = import "LrDialogs"
local LrTasks         = import "LrTasks"
local LrApplication   = import "LrApplication"
local LrProgressScope = import "LrProgressScope"
local LrPathUtils     = import "LrPathUtils"
local LrHttp          = import "LrHttp"
local LrColor         = import "LrColor"

local logger = import "LrLogger"("WordPressExport")
logger:enable("logfile")

local WordPressAPI = require "WordPressAPI"
local Utils        = require "Utils"


--------------------------------------------------------------------------------
-- Export Service Provider table
--------------------------------------------------------------------------------

local exportServiceProvider = {}

-- This is an export-only plugin, not a publish service.
exportServiceProvider.supportsIncrementalPublish = false

-- We use Lightroom's built-in File Settings and Image Sizing sections.
exportServiceProvider.hideSections  = {}
exportServiceProvider.allowFileFormats = { "JPEG", "PNG", "ORIGINAL" }
exportServiceProvider.allowColorSpaces = nil -- allow all

--- Default export preset values. These are saved/restored with presets.
exportServiceProvider.exportPresetFields = {
    { key = "wp_siteUrl",         default = "" },
    { key = "wp_username",        default = "" },
    { key = "wp_appPassword",     default = "" },
    { key = "wp_connectionStatus", default = "" },

    { key = "wp_destination",     default = "new" }, -- "new" or "existing"

    { key = "wp_postType",        default = "post" },
    { key = "wp_postTitle",       default = "" },
    { key = "wp_postStatus",      default = "draft" },

    { key = "wp_searchQuery",     default = "" },
    { key = "wp_selectedPostId",  default = 0 },
    { key = "wp_selectedPostInfo", default = "" },
    { key = "wp_existingStatus",  default = "keep" },

    { key = "wp_setFeatured",     default = true },
    { key = "wp_stripExif",       default = true },

    -- Internal state (not user-visible, but stored)
    { key = "wp_postTypes",       default = "" }, -- JSON-encoded array
    { key = "wp_searchResults",   default = "" }, -- JSON-encoded array
}

--------------------------------------------------------------------------------
-- Dialog helpers
--------------------------------------------------------------------------------

--- Try to get the current collection name for pre-filling the post title.
local function getCollectionName()
    local catalog = LrApplication.activeCatalog()
    if catalog then
        local sources = catalog:getActiveSources()
        if sources and #sources > 0 then
            local source = sources[1]
            if source.getName then
                return source:getName()
            end
        end
    end
    return ""
end

--- Build popup menu items from post types JSON string.
local function postTypeMenuItems(postTypesJson)
    if not postTypesJson or postTypesJson == "" then
        return { { title = "(connect first)", value = "post" } }
    end

    local types = Utils.jsonDecode(postTypesJson)
    if not types or #types == 0 then
        return { { title = "(connect first)", value = "post" } }
    end

    local items = {}
    for _, t in ipairs(types) do
        items[#items + 1] = { title = t.title, value = t.value }
    end
    return items
end

--- Build popup menu items from search results JSON string.
local function searchResultMenuItems(resultsJson)
    if not resultsJson or resultsJson == "" then
        return { { title = "(search for a post)", value = 0 } }
    end

    local results = Utils.jsonDecode(resultsJson)
    if not results or #results == 0 then
        return { { title = "(no results)", value = 0 } }
    end

    local items = {}
    for _, r in ipairs(results) do
        local label = r.title
                      .. " (" .. (r.typeName or r.typeSlug or "")
                      .. " · " .. (r.status or "")
                      .. " · " .. tostring(r.attachmentCount or 0) .. " images)"
        items[#items + 1] = { title = label, value = r.id }
    end
    return items
end

--- Store the selected post's info text for display.
local function updateSelectedPostInfo(propertyTable)
    local resultsJson = propertyTable.wp_searchResults
    local selectedId = propertyTable.wp_selectedPostId

    if not resultsJson or resultsJson == "" or not selectedId or selectedId == 0 then
        propertyTable.wp_selectedPostInfo = ""
        return
    end

    local results = Utils.jsonDecode(resultsJson)
    if not results then return end

    for _, r in ipairs(results) do
        if r.id == selectedId then
            propertyTable.wp_selectedPostInfo = (r.typeName or "")
                .. " · " .. (r.status or "")
                .. " · " .. tostring(r.attachmentCount or 0) .. " images"
            return
        end
    end
end

--------------------------------------------------------------------------------
-- Dialog sections
--------------------------------------------------------------------------------

function exportServiceProvider.sectionsForTopOfDialog(f, propertyTable)
    -- Pre-fill title from collection name if empty
    if propertyTable.wp_postTitle == "" then
        propertyTable.wp_postTitle = getCollectionName()
    end

    return {
        ---------------------
        -- Connection Section
        ---------------------
        {
            title = "WordPress Connection",

            synopsis = LrView.bind {
                key = "wp_connectionStatus",
                transform = function(value)
                    if value and value ~= "" then return value end
                    return "Not connected"
                end,
            },

            f:row {
                f:static_text {
                    title     = "Site URL:",
                    alignment = "right",
                    width     = LrView.share "label_width",
                },
                f:edit_field {
                    value         = LrView.bind "wp_siteUrl",
                    width_in_chars = 35,
                    tooltip       = "e.g. https://tiagsspace.com",
                },
            },

            f:row {
                f:static_text {
                    title     = "Username:",
                    alignment = "right",
                    width     = LrView.share "label_width",
                },
                f:edit_field {
                    value         = LrView.bind "wp_username",
                    width_in_chars = 25,
                },
            },

            f:row {
                f:static_text {
                    title     = "App Password:",
                    alignment = "right",
                    width     = LrView.share "label_width",
                },
                f:edit_field {
                    value         = LrView.bind "wp_appPassword",
                    width_in_chars = 25,
                },
            },

            f:row {
                f:push_button {
                    title  = "Test Connection",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            propertyTable.wp_connectionStatus = "Connecting..."
                            local name, err = WordPressAPI.testConnection(
                                propertyTable.wp_siteUrl,
                                propertyTable.wp_username,
                                propertyTable.wp_appPassword
                            )
                            if name then
                                propertyTable.wp_connectionStatus = "Connected as " .. name .. " ✓"
                                -- Fetch post types on successful connection
                                local types, typesErr = WordPressAPI.fetchPostTypes(
                                    propertyTable.wp_siteUrl,
                                    propertyTable.wp_username,
                                    propertyTable.wp_appPassword
                                )
                                if types then
                                    propertyTable.wp_postTypes = Utils.jsonEncode(types)
                                end
                            else
                                propertyTable.wp_connectionStatus = "✗ " .. (err or "Unknown error")
                            end
                        end)
                    end,
                },

                f:static_text {
                    title           = LrView.bind "wp_connectionStatus",
                    fill_horizontal = 1,
                },
            },
        },

        ---------------------
        -- Destination Section
        ---------------------
        {
            title = "Destination",

            synopsis = LrView.bind {
                key = "wp_destination",
                transform = function(value)
                    if value == "existing" then return "Existing Post" end
                    return "New Post"
                end,
            },

            f:row {
                f:radio_button {
                    title = "New Post",
                    value = LrView.bind "wp_destination",
                    checked_value = "new",
                },
                f:radio_button {
                    title = "Existing Post",
                    value = LrView.bind "wp_destination",
                    checked_value = "existing",
                },
            },

            -- New Post sub-section
            f:group_box {
                title = "New Post",
                fill_horizontal = 1,

                visible = LrView.bind {
                    key = "wp_destination",
                    transform = function(value) return value == "new" end,
                },

                f:row {
                    f:static_text {
                        title     = "Post Type:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:popup_menu {
                        value = LrView.bind "wp_postType",
                        items = LrView.bind {
                            key = "wp_postTypes",
                            transform = postTypeMenuItems,
                        },
                        width_in_chars = 25,
                    },
                },

                f:row {
                    f:static_text {
                        title     = "Title:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:edit_field {
                        value         = LrView.bind "wp_postTitle",
                        width_in_chars = 35,
                    },
                },

                f:row {
                    f:static_text {
                        title     = "Status:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:popup_menu {
                        value = LrView.bind "wp_postStatus",
                        items = {
                            { title = "Draft",     value = "draft" },
                            { title = "Published", value = "publish" },
                        },
                        width_in_chars = 15,
                    },
                },
            },

            -- Existing Post sub-section
            f:group_box {
                title = "Existing Post",
                fill_horizontal = 1,

                visible = LrView.bind {
                    key = "wp_destination",
                    transform = function(value) return value == "existing" end,
                },

                f:row {
                    f:static_text {
                        title     = "Search:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:edit_field {
                        value         = LrView.bind "wp_searchQuery",
                        width_in_chars = 30,
                        tooltip       = "Type at least 3 characters to search",
                    },
                    f:push_button {
                        title  = "Search",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local query = propertyTable.wp_searchQuery
                                if not query or #query < 3 then
                                    LrDialogs.message("Search", "Please type at least 3 characters.", "info")
                                    return
                                end

                                local typesJson = propertyTable.wp_postTypes
                                if not typesJson or typesJson == "" then
                                    LrDialogs.message("Search", "Connect to WordPress first.", "info")
                                    return
                                end

                                local postTypes = Utils.jsonDecode(typesJson)
                                local results = WordPressAPI.searchPosts(
                                    propertyTable.wp_siteUrl,
                                    propertyTable.wp_username,
                                    propertyTable.wp_appPassword,
                                    query,
                                    postTypes
                                )

                                propertyTable.wp_searchResults = Utils.jsonEncode(results)
                                if #results > 0 then
                                    propertyTable.wp_selectedPostId = results[1].id
                                    updateSelectedPostInfo(propertyTable)
                                else
                                    propertyTable.wp_selectedPostId = 0
                                    propertyTable.wp_selectedPostInfo = ""
                                end
                            end)
                        end,
                    },
                },

                f:row {
                    f:static_text {
                        title     = "Result:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:popup_menu {
                        value = LrView.bind "wp_selectedPostId",
                        items = LrView.bind {
                            key = "wp_searchResults",
                            transform = searchResultMenuItems,
                        },
                        width_in_chars = 40,
                    },
                },

                f:row {
                    f:static_text {
                        title     = "",
                        width     = LrView.share "label_width",
                    },
                    f:static_text {
                        title = LrView.bind "wp_selectedPostInfo",

                    },
                },

                f:row {
                    f:static_text {
                        title     = "Status:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:popup_menu {
                        value = LrView.bind "wp_existingStatus",
                        items = {
                            { title = "Keep current", value = "keep" },
                            { title = "Draft",        value = "draft" },
                            { title = "Published",    value = "publish" },
                        },
                        width_in_chars = 15,
                    },
                },
            },
        },

        ---------------------
        -- Upload Options Section
        ---------------------
        {
            title = "Upload Options",

            f:row {
                f:checkbox {
                    title = "Set first image as featured (new posts only)",
                    value = LrView.bind "wp_setFeatured",
                },
            },

            f:row {
                f:checkbox {
                    title = "Strip EXIF metadata (use Lightroom's Metadata section)",
                    value = LrView.bind "wp_stripExif",
                    tooltip = "Reminder: configure EXIF stripping in Lightroom's Metadata export section above.",
                },
            },
        },
    }
end

--------------------------------------------------------------------------------
-- Pre-export validation
--------------------------------------------------------------------------------

function exportServiceProvider.updateExportSettings(exportSettings)
    -- Called before export starts — can validate and modify settings
end

--------------------------------------------------------------------------------
-- Export processing
--------------------------------------------------------------------------------

function exportServiceProvider.processRenderedPhotos(functionContext, exportContext)
    local exportSession  = exportContext.exportSession
    local exportSettings = exportContext.propertyTable
    local nPhotos        = exportSession:countRenditions()

    logger:trace("Starting export of " .. nPhotos .. " photos")

    -- Validation
    if nPhotos == 0 then
        LrDialogs.message("WordPress Export", "No photos to export.", "warning")
        return
    end

    if nPhotos > 100 then
        LrDialogs.message("WordPress Export",
            "Maximum 100 images per export. You selected " .. nPhotos .. ".",
            "critical")
        return
    end

    local siteUrl     = exportSettings.wp_siteUrl
    local username    = exportSettings.wp_username
    local appPassword = exportSettings.wp_appPassword

    if not siteUrl or siteUrl == "" then
        LrDialogs.message("WordPress Export", "No site URL configured.", "critical")
        return
    end

    -- Determine post ID and starting menu_order
    local postId
    local postRestBase
    local startingOrder = 0
    local postTitle     = ""
    local isNewPost     = (exportSettings.wp_destination == "new")

    if isNewPost then
        -- Look up the rest_base for the selected post type
        local postTypesJson = exportSettings.wp_postTypes
        local postTypes = Utils.jsonDecode(postTypesJson) or {}
        local selectedType = exportSettings.wp_postType or "post"
        postRestBase = "posts" -- default

        for _, pt in ipairs(postTypes) do
            if pt.value == selectedType then
                postRestBase = pt.restBase
                break
            end
        end

        postTitle = exportSettings.wp_postTitle or ""
        if postTitle == "" then
            postTitle = "Untitled"
        end

        local postData, err = WordPressAPI.createPost(
            siteUrl, username, appPassword,
            postRestBase, postTitle,
            exportSettings.wp_postStatus or "draft"
        )

        if not postData then
            LrDialogs.message("WordPress Export",
                "Failed to create post: " .. (err or "Unknown error"),
                "critical")
            return
        end

        postId = postData.id
        startingOrder = 0
        logger:trace("Created new post ID: " .. postId)
    else
        -- Existing post
        postId = exportSettings.wp_selectedPostId
        if not postId or postId == 0 then
            LrDialogs.message("WordPress Export", "No post selected.", "critical")
            return
        end

        -- Determine rest_base from search results
        local resultsJson = exportSettings.wp_searchResults
        local results = Utils.jsonDecode(resultsJson) or {}
        postRestBase = "posts"

        for _, r in ipairs(results) do
            if r.id == postId then
                -- Look up rest_base from post types
                local postTypesJson = exportSettings.wp_postTypes
                local postTypes = Utils.jsonDecode(postTypesJson) or {}
                for _, pt in ipairs(postTypes) do
                    if pt.value == r.typeSlug then
                        postRestBase = pt.restBase
                        break
                    end
                end
                postTitle = r.title or ""
                break
            end
        end

        -- Get max existing menu_order for correct append position
        local maxOrder = WordPressAPI.getMaxMenuOrder(
            siteUrl, username, appPassword, postId
        )
        startingOrder = maxOrder + 1
        logger:trace("Appending to post " .. postId .. ", starting order: " .. startingOrder)
    end

    -- Build slug for filenames
    local slug = Utils.slugify(postTitle)

    -- Upload photos sequentially
    local progress = LrProgressScope({
        title            = "Uploading to WordPress",
        functionContext  = functionContext,
    })

    local successes = {}
    local failures  = {}
    local index     = 0

    for i, rendition in exportSession:renditions() do
        if progress:isCanceled() then
            logger:trace("Export canceled by user at photo " .. i)
            break
        end

        local success, pathOrMessage = rendition:waitForRender()

        if success then
            index = index + 1
            local ext = LrPathUtils.extension(pathOrMessage):lower()
            local filename = Utils.buildFilename(postTitle, index, nPhotos, ext)
            local menuOrder = startingOrder + (index - 1)

            progress:setPortionComplete(index - 1, nPhotos)
            progress:setCaption("Uploading " .. filename .. " (" .. index .. " of " .. nPhotos .. ")")

            logger:trace("Uploading " .. filename .. " (menu_order: " .. menuOrder .. ")")

            local ok, result = pcall(function()
                return WordPressAPI.uploadMedia(
                    siteUrl, username, appPassword,
                    pathOrMessage, postId, menuOrder, filename
                )
            end)

            if ok and result then
                successes[#successes + 1] = {
                    id       = result.id,
                    filename = filename,
                }
                logger:trace("Success: " .. filename .. " → media ID " .. result.id)
            else
                local errMsg = "Unknown error"
                if not ok then
                    errMsg = tostring(result) -- pcall error message
                elseif type(result) == "string" then
                    errMsg = result
                end
                failures[#failures + 1] = {
                    filename = filename,
                    error    = errMsg,
                }
                logger:error("Failed: " .. filename .. " — " .. errMsg)
            end
        else
            failures[#failures + 1] = {
                filename = "rendition " .. i,
                error    = tostring(pathOrMessage),
            }
        end
    end

    progress:setPortionComplete(nPhotos, nPhotos)

    -- Set featured image (first attachment, new posts only)
    if isNewPost and exportSettings.wp_setFeatured and #successes > 0 then
        logger:trace("Setting featured image: media ID " .. successes[1].id)
        WordPressAPI.updatePost(
            siteUrl, username, appPassword,
            postRestBase, postId,
            { featured_media = successes[1].id }
        )
    end

    -- Apply status override for existing posts
    if not isNewPost and exportSettings.wp_existingStatus ~= "keep" then
        logger:trace("Updating post status to: " .. exportSettings.wp_existingStatus)
        WordPressAPI.updatePost(
            siteUrl, username, appPassword,
            postRestBase, postId,
            { status = exportSettings.wp_existingStatus }
        )
    end

    progress:done()

    -- Show summary dialog
    local editUrl = siteUrl:gsub("/$", "")
                    .. "/wp-admin/post.php?post=" .. postId .. "&action=edit"
    local previewUrl = siteUrl:gsub("/$", "")
                       .. "/?p=" .. postId .. "&preview=true"

    local summaryMsg = "Uploaded " .. #successes .. " of " .. nPhotos .. " images."
    if #failures > 0 then
        summaryMsg = summaryMsg .. "\n\n" .. #failures .. " failed:"
        for _, fail in ipairs(failures) do
            summaryMsg = summaryMsg .. "\n  • " .. fail.filename .. ": " .. fail.error
        end
    end

    local result = LrDialogs.confirm(
        "WordPress Export Complete",
        summaryMsg,
        "Open Editor",
        "Preview Post",
        "Close"
    )

    if result == "ok" then
        LrHttp.openUrlInBrowser(editUrl)
    elseif result == "cancel" then
        LrHttp.openUrlInBrowser(previewUrl)
    end
end

return exportServiceProvider
