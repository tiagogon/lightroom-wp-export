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
    { key = "wp_siteUrl",        default = "" },
    { key = "wp_username",       default = "" },
    { key = "wp_appPassword",    default = "" },

    { key = "wp_destination",     default = "new" }, -- "new" or "existing"

    { key = "wp_postType",        default = "post" },
    { key = "wp_postTitle",       default = "" },
    { key = "wp_postStatus",      default = "draft" },
    { key = "wp_dateSource",      default = "none" }, -- "none" | "earliest_photo" | "custom"
    { key = "wp_customDate",      default = "" }, -- YYYY-MM-DD HH:MM

    { key = "wp_searchQuery",     default = "" },
    { key = "wp_selectedPostId",  default = 0 },
    { key = "wp_selectedPostInfo", default = "" },
    { key = "wp_existingStatus",  default = "keep" },

    { key = "wp_setFeatured",     default = true },
    { key = "wp_stripExif",       default = true },

    -- Internal state (not user-visible, but stored)
    { key = "wp_searchResults",   default = "" }, -- JSON-encoded array
    { key = "wp_connectionStatus", default = "" },
    { key = "wp_postTypes",       default = "" }, -- JSON-encoded post types
}

local MONTHS_SHORT = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

--- Parse a date input in YYYY-MM-DD HH:MM and return normalized parts.
local function parseManualDateInput(value)
    local input = tostring(value or "")
    local y, m, d, h, min = input:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)$")
    if not y then
        return nil, "Use format YYYY-MM-DD HH:MM."
    end

    y, m, d, h, min = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(min)
    if not y or not m or not d or not h or not min then
        return nil, "Invalid date/time values."
    end

    if m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or min > 59 then
        return nil, "Date/time values are out of range."
    end

    local ts = os.time({ year = y, month = m, day = d, hour = h, min = min, sec = 0 })
    if not ts then
        return nil, "Invalid date/time."
    end

    local parts = os.date("*t", ts)
    if not parts
        or parts.year ~= y
        or parts.month ~= m
        or parts.day ~= d
        or parts.hour ~= h
        or parts.min ~= min then
        return nil, "Invalid calendar date/time."
    end

    return {
        year = y,
        month = m,
        day = d,
        hour = h,
        min = min,
    }
end

--- Convert parsed date parts to WordPress REST API date format.
local function toWpDateString(parts)
    return string.format(
        "%04d-%02d-%02dT%02d:%02d:00",
        parts.year,
        parts.month,
        parts.day,
        parts.hour,
        parts.min
    )
end

--- Create a human-readable date label from parsed date parts.
local function formatHumanDate(parts)
    local monthLabel = MONTHS_SHORT[parts.month] or tostring(parts.month)
    return string.format(
        "%02d %s %04d, %02d:%02d",
        parts.day,
        monthLabel,
        parts.year,
        parts.hour,
        parts.min
    )
end

--- Parse a photo date string from Lightroom metadata.
local function parsePhotoDateString(value)
    if value == nil then
        return nil
    end

    if type(value) == "number" and value > 0 then
        local partsNum = os.date("*t", value)
        if partsNum then
            return {
                year = partsNum.year,
                month = partsNum.month,
                day = partsNum.day,
                hour = partsNum.hour,
                min = partsNum.min,
                sec = partsNum.sec,
                ts = value,
            }
        end
    end

    local text = tostring(value or "")
    if text == "" then
        return nil
    end

    -- Common formats handled:
    -- 1) YYYY-MM-DD HH:MM:SS
    -- 2) YYYY:MM:DD HH:MM:SS (EXIF)
    -- 3) YYYY-MM-DDTHH:MM:SS(+TZ)
    -- 4) YYYY-MM-DD HH:MM
    -- 5) YYYY:MM:DD HH:MM
    -- 6) YYYY-MM-DD (date only)
    local y, m, d, h, min, s = text:match("^(%d%d%d%d)[-:](%d%d)[-:](%d%d)[T%s](%d%d):(%d%d):(%d%d)")
    if not y then
        y, m, d, h, min = text:match("^(%d%d%d%d)[-:](%d%d)[-:](%d%d)[T%s](%d%d):(%d%d)")
        s = "00"
    end
    if not y then
        y, m, d = text:match("^(%d%d%d%d)[-:](%d%d)[-:](%d%d)$")
        h, min, s = "00", "00", "00"
    end
    if not y then
        return nil
    end

    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    h, min, s = tonumber(h or 0), tonumber(min or 0), tonumber(s or 0)
    if not y or not m or not d or not h or not min or not s then
        return nil
    end

    local ts = os.time({ year = y, month = m, day = d, hour = h, min = min, sec = s })
    if not ts then
        return nil
    end

    local parts = os.date("*t", ts)
    if not parts
        or parts.year ~= y
        or parts.month ~= m
        or parts.day ~= d
        or parts.hour ~= h
        or parts.min ~= min then
        return nil
    end

    return {
        year = parts.year,
        month = parts.month,
        day = parts.day,
        hour = parts.hour,
        min = parts.min,
        sec = parts.sec,
        ts = ts,
    }
end

local function safeGetFormatted(photo, key)
    return photo:getFormattedMetadata(key)
end

local function safeGetRaw(photo, key)
    return photo:getRawMetadata(key)
end

local function stringifyMetaValue(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "table" then
        return "<table>"
    end
    local text = tostring(value)
    if #text > 120 then
        return text:sub(1, 120) .. "..."
    end
    return text
end

local function logPhotoDateProbe(photo, index)
    local path = safeGetRaw(photo, "path")
    local fileName = safeGetFormatted(photo, "fileName")
    local label = fileName or path or ("photo " .. tostring(index))

    local probeKeys = {
        "dateTimeOriginal",
        "dateTime",
        "dateCreated",
        "captureTime",
        "dateTimeOriginalISO8601",
        "dateTimeISO8601",
    }

    logger:trace("Date probe " .. tostring(index) .. ": " .. tostring(label))
    for _, key in ipairs(probeKeys) do
        local formattedVal = safeGetFormatted(photo, key)
        local rawVal = safeGetRaw(photo, key)
        logger:trace(
            "  " .. key
            .. " | formatted=" .. stringifyMetaValue(formattedVal)
            .. " | raw=" .. stringifyMetaValue(rawVal)
        )
    end
end

--- Extract capture date from a photo using common metadata keys.
local function extractPhotoCaptureParts(photo)
    if not photo then
        return nil
    end

    local formattedKeys = {
        "dateTimeOriginal",
        "dateTime",
        "dateCreated",
        "captureTime",
        "dateTimeISO8601",
        "dateTimeOriginalISO8601",
    }
    for _, key in ipairs(formattedKeys) do
        local value = safeGetFormatted(photo, key)
        if value and value ~= "" then
            local parsed = parsePhotoDateString(value)
            if parsed then
                return parsed
            end
        end
    end

    local rawDateKeys = {
        "dateTimeOriginal",
        "dateTime",
        "dateCreated",
        "captureTime",
        "dateTimeOriginalISO8601",
        "dateTimeISO8601",
    }
    for _, key in ipairs(rawDateKeys) do
        local value = safeGetRaw(photo, key)
        if value and value ~= "" then
            local parsed = parsePhotoDateString(value)
            if parsed then
                return parsed
            end
        end
    end

    local captureTs = safeGetRaw(photo, "captureTime")
    if type(captureTs) == "number" and captureTs > 0 then
        local parts = os.date("*t", captureTs)
        if parts then
            return {
                year = parts.year,
                month = parts.month,
                day = parts.day,
                hour = parts.hour,
                min = parts.min,
                sec = parts.sec,
                ts = captureTs,
            }
        end
    end

    return nil
end

--- Return the earliest capture date found across photos to export.
local function resolveEarliestPhotoDate(exportSession)
    local photos

    if exportSession and type(exportSession.photosToExport) == "function" then
        local okPhotos, exportPhotos = pcall(function()
            return exportSession:photosToExport()
        end)
        if okPhotos and type(exportPhotos) == "table" and #exportPhotos > 0 then
            photos = exportPhotos
            logger:trace("Date source probe: using exportSession:photosToExport() with " .. tostring(#photos) .. " photos")
        end
    end

    -- Fallback: use Lightroom's current target photos when session list is unavailable.
    if not photos or #photos == 0 then
        local okCatalog, targetPhotos = pcall(function()
            local catalog = LrApplication.activeCatalog()
            if not catalog then return nil end

            local selected = catalog:getTargetPhotos()
            if selected and #selected > 0 then
                return selected
            end

            if type(catalog.getMultipleSelectedOrAllPhotos) == "function" then
                local multi = catalog:getMultipleSelectedOrAllPhotos()
                if multi and #multi > 0 then
                    return multi
                end
            end

            return nil
        end)

        if okCatalog and type(targetPhotos) == "table" and #targetPhotos > 0 then
            photos = targetPhotos
            logger:trace("Date source probe: using catalog target photos with " .. tostring(#photos) .. " photos")
        end
    end

    if not photos or #photos == 0 then
        return nil, "Could not determine the exported photo list for date detection."
    end

    local earliest
    local unresolvedCount = 0

    local function scanPhotos()
        for i, photo in ipairs(photos) do
            local parsed = extractPhotoCaptureParts(photo)
            if parsed and (not earliest or parsed.ts < earliest.ts) then
                earliest = parsed
                logger:trace("Date source probe: candidate from photo " .. tostring(i) .. " => " .. toWpDateString(parsed))
            elseif not parsed then
                unresolvedCount = unresolvedCount + 1
                if unresolvedCount <= 3 then
                    logPhotoDateProbe(photo, i)
                end
            end
        end
    end

    local catalog = LrApplication.activeCatalog()
    if catalog and type(catalog.withReadAccessDo) == "function" then
        local okRead, readErr = pcall(function()
            catalog:withReadAccessDo(function()
                scanPhotos()
            end)
        end)
        if not okRead then
            logger:trace("Date source probe: withReadAccessDo failed: " .. tostring(readErr))
            scanPhotos()
        end
    else
        scanPhotos()
    end

    if not earliest then
        logger:trace("Date source probe: no parseable capture date found across " .. tostring(#photos) .. " photos")
        return nil, "No usable capture date was found in the exported photos."
    end

    return earliest
end

local function customDatePreviewLabel(value)
    local parts = parseManualDateInput(value)
    if not parts then
        return "Will save draft date as: (enter a valid date)"
    end
    return "Will save draft date as: " .. formatHumanDate(parts)
end

--- Resolve optional WordPress post date based on the selected date source.
local function resolveOptionalPostDate(exportSettings, exportSession)
    local source = exportSettings.wp_dateSource or "none"

    if source == "none" then
        return nil
    end

    if source == "custom" then
        local parts, err = parseManualDateInput(exportSettings.wp_customDate)
        if not parts then
            return nil, err
        end
        return toWpDateString(parts)
    end

    if source == "earliest_photo" then
        local earliest, err = resolveEarliestPhotoDate(exportSession)
        if not earliest then
            return nil, err
        end
        return toWpDateString(earliest)
    end

    return nil, "Invalid date source selection."
end

--------------------------------------------------------------------------------
-- Dialog helpers
--------------------------------------------------------------------------------

--- Try to get the current collection name for pre-filling the post title.
--- Wrapped in pcall because catalog access may require a task context.
local function getCollectionName()
    local ok, result = pcall(function()
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
    end)
    if ok then
        logger:trace("Collection name: " .. tostring(result))
        return result
    end
    logger:warn("Could not get collection name: " .. tostring(result))
    return ""
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
    logger:trace("Building export dialog sections")

    -- Pre-fill title from collection name if empty
    if propertyTable.wp_postTitle == "" then
        propertyTable.wp_postTitle = getCollectionName()
    end

    -- Build connection status message from export settings
    local connectionMsg = propertyTable.wp_connectionStatus
    if not connectionMsg or connectionMsg == "" then
        if propertyTable.wp_siteUrl and propertyTable.wp_siteUrl ~= "" then
            connectionMsg = "Connection not tested yet."
        else
            connectionMsg = ""
        end
    end

    return {
        ---------------------
        -- Connection
        ---------------------
        {
            title    = "WordPress Connection",
            synopsis = LrView.bind {
                key = "wp_connectionStatus",
                transform = function(value)
                    if value and value ~= "" then return value end
                    return "Not configured"
                end,
            },

            f:row {
                f:static_text {
                    title     = "Site URL:",
                    alignment = "right",
                    width     = LrView.share "label_width",
                },
                f:edit_field {
                    value          = LrView.bind "wp_siteUrl",
                    width_in_chars = 35,
                    tooltip        = "e.g. https://tiags.space",
                },
            },

            f:row {
                f:static_text {
                    title     = "Username:",
                    alignment = "right",
                    width     = LrView.share "label_width",
                },
                f:edit_field {
                    value          = LrView.bind "wp_username",
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
                    value          = LrView.bind "wp_appPassword",
                    width_in_chars = 25,
                },
            },

            f:row {
                f:push_button {
                    title  = "Test Connection",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            logger:trace("Testing connection to " .. tostring(propertyTable.wp_siteUrl))
                            propertyTable.wp_connectionStatus = "Connecting..."
                            local name, err = WordPressAPI.testConnection(
                                propertyTable.wp_siteUrl,
                                propertyTable.wp_username,
                                propertyTable.wp_appPassword
                            )
                            if name then
                                logger:trace("Connected as: " .. name)
                                propertyTable.wp_connectionStatus = "Connected as " .. name

                                local types, typesErr = WordPressAPI.fetchPostTypes(
                                    propertyTable.wp_siteUrl,
                                    propertyTable.wp_username,
                                    propertyTable.wp_appPassword
                                )
                                if types then
                                    logger:trace("Fetched " .. #types .. " post types")
                                    propertyTable.wp_postTypes = Utils.jsonEncode(types)
                                else
                                    logger:warn("Failed to fetch post types: " .. tostring(typesErr))
                                end
                            else
                                logger:warn("Connection failed: " .. tostring(err))
                                propertyTable.wp_connectionStatus = "Error: " .. (err or "Unknown error")
                            end
                        end)
                    end,
                },

                f:static_text {
                    title           = LrView.bind "wp_connectionStatus",
                    fill_horizontal = 1,
                },
            },

            f:separator { fill_horizontal = 1 },

            f:static_text {
                title           = "Create an Application Password in WordPress: Users > Profile > Application Passwords.\nEnter a name (e.g. \"Lightroom\"), click Add New, and paste the generated password above.\nYour site must use HTTPS. The REST API must be enabled (it is by default).",
                fill_horizontal = 1,
                height_in_lines = 3,
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
                            transform = function(value)
                                if not value or value == "" then
                                    return { { title = "(click Test Connection first)", value = "post" } }
                                end
                                local types = Utils.jsonDecode(value)
                                if not types or #types == 0 then
                                    return { { title = "(click Test Connection first)", value = "post" } }
                                end
                                local items = {}
                                for _, t in ipairs(types) do
                                    items[#items + 1] = { title = t.title, value = t.value }
                                end
                                return items
                            end,
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

                f:row {
                    f:static_text {
                        title     = "Date source:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:radio_button {
                        title = "No custom date",
                        value = LrView.bind "wp_dateSource",
                        checked_value = "none",
                    },
                },

                f:row {
                    f:static_text {
                        title = "",
                        width = LrView.share "label_width",
                    },
                    f:radio_button {
                        title = "Use earliest exported photo date",
                        value = LrView.bind "wp_dateSource",
                        checked_value = "earliest_photo",
                    },
                },

                f:row {
                    f:static_text {
                        title = "",
                        width = LrView.share "label_width",
                    },
                    f:radio_button {
                        title = "Enter custom date",
                        value = LrView.bind "wp_dateSource",
                        checked_value = "custom",
                    },
                },

                f:row {
                    visible = LrView.bind {
                        key = "wp_dateSource",
                        transform = function(value) return value == "custom" end,
                    },
                    f:static_text {
                        title     = "Publish date:",
                        alignment = "right",
                        width     = LrView.share "label_width",
                    },
                    f:edit_field {
                        value          = LrView.bind "wp_customDate",
                        width_in_chars = 20,
                    },
                },

                f:row {
                    visible = LrView.bind {
                        key = "wp_dateSource",
                        transform = function(value) return value == "custom" end,
                    },
                    f:static_text {
                        title = "",
                        width = LrView.share "label_width",
                    },
                    f:static_text {
                        title = "Use YYYY-MM-DD HH:MM",
                    },
                },

                f:row {
                    visible = LrView.bind {
                        key = "wp_dateSource",
                        transform = function(value) return value == "custom" end,
                    },
                    f:static_text {
                        title = "",
                        width = LrView.share "label_width",
                    },
                    f:static_text {
                        title = LrView.bind {
                            key = "wp_customDate",
                            transform = customDatePreviewLabel,
                        },
                    },
                },

                f:row {
                    visible = LrView.bind {
                        key = "wp_dateSource",
                        transform = function(value) return value == "earliest_photo" end,
                    },
                    f:static_text {
                        title = "",
                        width = LrView.share "label_width",
                    },
                    f:static_text {
                        title = "Earliest date is resolved from exported photos at export time.",
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
                                    LrDialogs.message("Search", "Click Test Connection first.", "info")
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
    local source = exportSettings.wp_dateSource or "none"
    if source ~= "none" and source ~= "earliest_photo" and source ~= "custom" then
        exportSettings.wp_dateSource = "none"
        source = "none"
    end

    if source == "custom" then
        local _, err = parseManualDateInput(exportSettings.wp_customDate)
        if err then
            LrDialogs.message(
                "WordPress Export",
                "Invalid custom date. " .. err,
                "critical"
            )
        end
    end
end

--------------------------------------------------------------------------------
-- Export processing
--------------------------------------------------------------------------------

function exportServiceProvider.processRenderedPhotos(functionContext, exportContext)
    local exportSession  = exportContext.exportSession
    local exportSettings = exportContext.propertyTable
    local nPhotos        = exportSession:countRenditions()

    logger:trace("=== Starting WordPress export ===")
    logger:trace("Photos: " .. nPhotos .. ", Destination: " .. tostring(exportSettings.wp_destination))

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
        LrDialogs.message("WordPress Upload",
            "No site URL configured. Enter your WordPress site URL in the Connection section above.",
            "critical")
        return
    end
    if not username or username == "" or not appPassword or appPassword == "" then
        LrDialogs.message("WordPress Upload",
            "Missing credentials. Enter your username and App Password in the Connection section above.",
            "critical")
        return
    end

    -- Determine post ID and starting menu_order
    local postId
    local postRestBase
    local postTypeSlug  = "post"
    local startingOrder = 0
    local postTitle     = ""
    local isNewPost     = (exportSettings.wp_destination == "new")

    if isNewPost then
        -- Look up the rest_base for the selected post type
        local postTypesJson = exportSettings.wp_postTypes
        local postTypes = Utils.jsonDecode(postTypesJson) or {}
        local selectedType = exportSettings.wp_postType or "post"
        postTypeSlug = selectedType
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

        logger:trace("Creating new post: type=" .. selectedType .. ", restBase=" .. postRestBase .. ", title=" .. postTitle)
        local postDate, dateErr = resolveOptionalPostDate(exportSettings, exportSession)
        if dateErr then
            LrDialogs.message("WordPress Export", "Date source error: " .. dateErr, "critical")
            return
        end

        local postData, err = WordPressAPI.createPost(
            siteUrl, username, appPassword,
            postRestBase, postTitle,
            exportSettings.wp_postStatus or "draft",
            postDate
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
                postTypeSlug = r.typeSlug or "post"
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

            local result, uploadErr = WordPressAPI.uploadMedia(
                siteUrl, username, appPassword,
                pathOrMessage, postId, menuOrder, filename
            )

            if result then
                successes[#successes + 1] = {
                    id       = result.id,
                    filename = filename,
                }
                logger:trace("Success: " .. filename .. " → media ID " .. result.id)
            else
                local errMsg = uploadErr or "Unknown error"
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
    logger:trace("=== Export complete: " .. #successes .. " succeeded, " .. #failures .. " failed ===")
    local editUrl = siteUrl:gsub("/$", "")
                    .. "/wp-admin/post.php?post=" .. postId .. "&action=edit"
    local previewUrl = siteUrl:gsub("/$", "")
                       .. "/?" .. (postTypeSlug ~= "post" and ("post_type=" .. postTypeSlug .. "&") or "")
                       .. "p=" .. postId .. "&preview=true"

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
