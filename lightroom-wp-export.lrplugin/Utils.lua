local LrPathUtils   = import "LrPathUtils"
local LrFileUtils   = import "LrFileUtils"

local Utils = {}

--------------------------------------------------------------------------------
-- Base64 encoding
--------------------------------------------------------------------------------

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Utils.encodeBase64(data)
    local result = {}
    local pad = 0
    local len = #data

    for i = 1, len, 3 do
        local a = data:byte(i)
        local b = i + 1 <= len and data:byte(i + 1) or 0
        local c = i + 2 <= len and data:byte(i + 2) or 0

        local n = a * 65536 + b * 256 + c

        result[#result + 1] = b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        result[#result + 1] = (i + 1 <= len) and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
        result[#result + 1] = (i + 2 <= len) and b64chars:sub(n % 64 + 1, n % 64 + 1) or "="
    end

    return table.concat(result)
end

--------------------------------------------------------------------------------
-- URL encoding
--------------------------------------------------------------------------------

function Utils.urlEncode(str)
    if not str then return "" end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

--- Convert a string to a URL-safe slug: lowercase, hyphens, no special chars.
function Utils.slugify(text)
    if not text or text == "" then
        return "untitled"
    end

    local slug = text:lower()
    -- Replace accented characters with ASCII equivalents
    slug = slug:gsub("[àáâãäå]", "a")
    slug = slug:gsub("[èéêë]", "e")
    slug = slug:gsub("[ìíîï]", "i")
    slug = slug:gsub("[òóôõö]", "o")
    slug = slug:gsub("[ùúûü]", "u")
    slug = slug:gsub("[ñ]", "n")
    slug = slug:gsub("[ç]", "c")
    -- Replace non-alphanumeric with hyphens
    slug = slug:gsub("[^%w%-]", "-")
    -- Collapse multiple hyphens
    slug = slug:gsub("%-+", "-")
    -- Trim leading/trailing hyphens
    slug = slug:gsub("^%-", ""):gsub("%-$", "")

    if slug == "" then
        return "untitled"
    end
    return slug
end

--- Pad a number with leading zeros. padNumber(3, 3) → "003"
function Utils.padNumber(n, digits)
    local s = tostring(n)
    while #s < digits do
        s = "0" .. s
    end
    return s
end

--- Build the renamed filename for an image.
--- e.g. slugify("Sunset at pier") + index 1 + digits 3 → "sunset-at-pier-001.jpg"
function Utils.buildFilename(title, index, total, extension)
    local slug = Utils.slugify(title)
    local digits = #tostring(total)
    if digits < 3 then digits = 3 end
    return slug .. "-" .. Utils.padNumber(index, digits) .. "." .. (extension or "jpg")
end

--- Rename a file on disk to a new filename in the same directory.
--- Returns the new full path, or nil + error.
function Utils.renameFile(originalPath, newFilename)
    local dir = LrPathUtils.parent(originalPath)
    local newPath = LrPathUtils.child(dir, newFilename)

    -- Avoid collision
    if LrFileUtils.exists(newPath) then
        newPath = LrPathUtils.addSuffix(newPath, "-" .. tostring(os.time()))
    end

    local success = LrFileUtils.move(originalPath, newPath)
    if success then
        return newPath
    else
        return nil, "Failed to rename file to " .. newFilename
    end
end

return Utils
