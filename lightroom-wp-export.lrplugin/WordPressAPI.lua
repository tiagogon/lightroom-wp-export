local LrHttp          = import "LrHttp"
local LrPathUtils     = import "LrPathUtils"
local LrFileUtils     = import "LrFileUtils"

local logger = import "LrLogger"("WordPressExport")
logger:enable("logfile")

local JSON  = require "PluginJSON"
local Utils = require "Utils"

local WordPressAPI = {}

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

--- Build the Basic Auth header value from username + application password.
local function authHeader(username, appPassword)
    local credentials = username .. ":" .. appPassword
    return "Basic " .. Utils.encodeBase64(credentials)
end

--- Normalise the site URL (strip trailing slash).
local function normaliseUrl(siteUrl)
    return siteUrl:gsub("/$", "")
end

--- Build full REST endpoint URL.
local function endpointUrl(siteUrl, path)
    return normaliseUrl(siteUrl) .. "/wp-json" .. path
end

--- Parse a JSON response body. Returns table or nil + error.
local function parseJson(body)
    if not body or body == "" then
        return nil, "Empty response"
    end

    local decoded = JSON.decode(body)
    if not decoded then
        return nil, "Failed to parse JSON"
    end

    return decoded
end

--- Make a GET request. Returns (decoded body, headers) or (nil, error string).
function WordPressAPI.apiGet(siteUrl, path, username, appPassword)
    local url = endpointUrl(siteUrl, path)
    logger:trace("GET " .. url)

    local headers = {
        { field = "Authorization", value = authHeader(username, appPassword) },
    }

    local body, respHeaders = LrHttp.get(url, headers)

    if not body then
        logger:error("GET failed: no response from " .. url)
        return nil, "No response from server. Check the site URL."
    end

    local decoded, err = parseJson(body)
    if not decoded then
        logger:error("GET JSON parse error: " .. (err or "unknown"))
        return nil, err
    end

    -- WP REST API returns { code, message, data } on errors
    if decoded.code and decoded.message then
        logger:error("GET API error: " .. decoded.message)
        return nil, decoded.message
    end

    return decoded, respHeaders
end

--- Make a POST request with JSON body. Returns (decoded body, headers) or (nil, error string).
function WordPressAPI.apiPost(siteUrl, path, username, appPassword, postBody)
    local url = endpointUrl(siteUrl, path)
    logger:trace("POST " .. url)

    local jsonBody = JSON.encode(postBody)
    local headers = {
        { field = "Authorization", value = authHeader(username, appPassword) },
        { field = "Content-Type",  value = "application/json" },
    }

    local body, respHeaders = LrHttp.post(url, jsonBody, headers)

    if not body then
        logger:error("POST failed: no response from " .. url)
        return nil, "No response from server."
    end

    local decoded, err = parseJson(body)
    if not decoded then
        logger:error("POST JSON parse error: " .. (err or "unknown"))
        return nil, err
    end

    if decoded.code and decoded.message then
        logger:error("POST API error: " .. decoded.message)
        return nil, decoded.message
    end

    return decoded, respHeaders
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

--- Test the connection. Returns username string on success, or (nil, error).
function WordPressAPI.testConnection(siteUrl, username, appPassword)
    if not siteUrl or siteUrl == "" then
        return nil, "Site URL is required."
    end
    if not username or username == "" then
        return nil, "Username is required."
    end
    if not appPassword or appPassword == "" then
        return nil, "Application Password is required."
    end

    local data, err = WordPressAPI.apiGet(siteUrl, "/wp/v2/users/me", username, appPassword)
    if not data then
        return nil, err
    end

    local name = data.name or data.slug or username
    logger:trace("Connected as: " .. name)
    return name
end

--------------------------------------------------------------------------------
-- Post Types
--------------------------------------------------------------------------------

--- Fetch available post types. Returns array of { label, value } for popup menus.
function WordPressAPI.fetchPostTypes(siteUrl, username, appPassword)
    local data, err = WordPressAPI.apiGet(siteUrl, "/wp/v2/types", username, appPassword)
    if not data then
        return nil, err
    end

    local types = {}
    for slug, info in pairs(data) do
        -- Skip non-viewable built-in types
        if info.rest_base and slug ~= "attachment" and slug ~= "wp_block"
           and slug ~= "wp_template" and slug ~= "wp_template_part"
           and slug ~= "wp_navigation" and slug ~= "wp_font_family"
           and slug ~= "wp_font_face" and slug ~= "wp_global_styles" then
            types[#types + 1] = {
                title = info.name or slug,
                value = slug,
                restBase = info.rest_base,
            }
        end
    end

    -- Sort alphabetically by title
    table.sort(types, function(a, b) return a.title < b.title end)

    logger:trace("Fetched " .. #types .. " post types")
    return types
end

--------------------------------------------------------------------------------
-- Search Posts
--------------------------------------------------------------------------------

--- Search posts across a specific post type. Returns array of result tables.
local function searchByType(siteUrl, username, appPassword, restBase, typeName, query)
    local path = "/wp/v2/" .. restBase
                 .. "?search=" .. Utils.urlEncode(query)
                 .. "&per_page=10"
                 .. "&_fields=id,title,status,type"
    local data, err = WordPressAPI.apiGet(siteUrl, path, username, appPassword)
    if not data then
        return {}
    end

    local results = {}
    for _, post in ipairs(data) do
        local title = ""
        if post.title and post.title.rendered then
            title = post.title.rendered
        end
        results[#results + 1] = {
            id       = post.id,
            title    = title,
            status   = post.status or "unknown",
            typeName = typeName,
            typeSlug = post.type,
        }
    end
    return results
end

--- Get the attachment count for a post. Returns number.
function WordPressAPI.getAttachmentCount(siteUrl, username, appPassword, postId)
    local path = "/wp/v2/media?parent=" .. postId .. "&per_page=1&_fields=id"
    local _, respHeaders = WordPressAPI.apiGet(siteUrl, path, username, appPassword)

    if respHeaders then
        for _, h in ipairs(respHeaders) do
            if h.field and h.field:lower() == "x-wp-total" then
                return tonumber(h.value) or 0
            end
        end
    end
    return 0
end

--- Get the highest menu_order among existing attachments. Returns number.
function WordPressAPI.getMaxMenuOrder(siteUrl, username, appPassword, postId)
    local path = "/wp/v2/media?parent=" .. postId
                 .. "&orderby=menu_order&order=desc&per_page=1"
                 .. "&_fields=menu_order"
    local data, err = WordPressAPI.apiGet(siteUrl, path, username, appPassword)

    if data and #data > 0 and data[1].menu_order then
        return data[1].menu_order
    end
    return -1
end

--- Search posts across ALL post types. Returns array of results with attachment counts.
function WordPressAPI.searchPosts(siteUrl, username, appPassword, query, postTypes)
    if not query or query == "" or #query < 3 then
        return {}
    end

    local allResults = {}

    for _, pt in ipairs(postTypes) do
        local results = searchByType(siteUrl, username, appPassword,
                                     pt.restBase, pt.title, query)
        for _, r in ipairs(results) do
            allResults[#allResults + 1] = r
        end
    end

    -- Fetch attachment count for each result
    for _, r in ipairs(allResults) do
        r.attachmentCount = WordPressAPI.getAttachmentCount(
            siteUrl, username, appPassword, r.id
        )
    end

    logger:trace("Search '" .. query .. "' found " .. #allResults .. " results")
    return allResults
end

--------------------------------------------------------------------------------
-- Create Post
--------------------------------------------------------------------------------

--- Create a new post. Returns (post data table) or (nil, error).
function WordPressAPI.createPost(siteUrl, username, appPassword, restBase, title, status)
    local body = {
        title  = title,
        status = status or "draft",
    }
    return WordPressAPI.apiPost(siteUrl, "/wp/v2/" .. restBase, username, appPassword, body)
end

--------------------------------------------------------------------------------
-- Upload Media
--------------------------------------------------------------------------------

--- Upload a single image file as a media attachment.
--- Returns (media data table) or (nil, error).
function WordPressAPI.uploadMedia(siteUrl, username, appPassword, filePath, postId, menuOrder, filename)
    local url = endpointUrl(siteUrl, "/wp/v2/media")
    logger:trace("Uploading media: " .. filename .. " to post " .. tostring(postId))

    -- Read file content
    local fileContent = LrFileUtils.readFile(filePath)
    if not fileContent then
        return nil, "Could not read file: " .. filePath
    end

    -- Determine MIME type
    local ext = LrPathUtils.extension(filePath):lower()
    local mimeType = "image/jpeg"
    if ext == "png" then
        mimeType = "image/png"
    elseif ext == "webp" then
        mimeType = "image/webp"
    end

    -- Build multipart content
    local mimeChunks = {
        {
            name     = "file",
            fileName = filename,
            filePath = filePath,
            contentType = mimeType,
        },
    }

    -- Additional form fields
    local postFields = {
        { name = "post",       value = tostring(postId) },
        { name = "menu_order", value = tostring(menuOrder) },
    }

    -- Merge into mimeChunks
    for _, field in ipairs(postFields) do
        mimeChunks[#mimeChunks + 1] = {
            name  = field.name,
            value = field.value,
        }
    end

    local headers = {
        { field = "Authorization", value = authHeader(username, appPassword) },
    }

    local body, respHeaders = LrHttp.postMultipart(url, mimeChunks, headers)

    if not body then
        logger:error("Upload failed: no response")
        return nil, "No response from server during upload."
    end

    local decoded, err = parseJson(body)
    if not decoded then
        logger:error("Upload JSON parse error: " .. (err or "unknown"))
        return nil, err
    end

    if decoded.code and decoded.message then
        logger:error("Upload API error: " .. decoded.message)
        return nil, decoded.message
    end

    logger:trace("Uploaded media ID: " .. tostring(decoded.id))
    return decoded
end

--------------------------------------------------------------------------------
-- Update Post (featured image, status)
--------------------------------------------------------------------------------

--- Update a post's fields (e.g. featured_media, status).
function WordPressAPI.updatePost(siteUrl, username, appPassword, restBase, postId, fields)
    local path = "/wp/v2/" .. restBase .. "/" .. postId
    return WordPressAPI.apiPost(siteUrl, path, username, appPassword, fields)
end

return WordPressAPI
