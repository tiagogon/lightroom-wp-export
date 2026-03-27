local LrPathUtils   = import "LrPathUtils"
local LrFileUtils   = import "LrFileUtils"

local Utils = {}

--------------------------------------------------------------------------------
-- JSON decode
--------------------------------------------------------------------------------

local function skipWhitespace(s, pos)
    return s:match("^%s*()", pos)
end

local function decodeString(s, pos)
    pos = pos + 1
    local parts = {}
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == '"' then
            return table.concat(parts), pos + 1
        elseif c == '\\' then
            pos = pos + 1
            local esc = s:sub(pos, pos)
            if esc == '"' then parts[#parts + 1] = '"'
            elseif esc == '\\' then parts[#parts + 1] = '\\'
            elseif esc == '/' then parts[#parts + 1] = '/'
            elseif esc == 'n' then parts[#parts + 1] = '\n'
            elseif esc == 'r' then parts[#parts + 1] = '\r'
            elseif esc == 't' then parts[#parts + 1] = '\t'
            elseif esc == 'b' then parts[#parts + 1] = '\b'
            elseif esc == 'f' then parts[#parts + 1] = '\f'
            elseif esc == 'u' then
                local hex = s:sub(pos + 1, pos + 4)
                local codepoint = tonumber(hex, 16)
                if codepoint and codepoint < 128 then
                    parts[#parts + 1] = string.char(codepoint)
                else
                    parts[#parts + 1] = "?"
                end
                pos = pos + 4
            end
            pos = pos + 1
        else
            parts[#parts + 1] = c
            pos = pos + 1
        end
    end
    return nil, "unterminated string"
end

local decodeValue

local function decodeArray(s, pos)
    pos = pos + 1
    pos = skipWhitespace(s, pos)
    local arr = {}
    if s:sub(pos, pos) == ']' then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = decodeValue(s, pos)
        if val == nil and pos == nil then return nil end
        arr[#arr + 1] = val
        pos = skipWhitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = skipWhitespace(s, pos + 1)
        else
            return nil, "expected , or ]"
        end
    end
end

local function decodeObject(s, pos)
    pos = pos + 1
    pos = skipWhitespace(s, pos)
    local obj = {}
    if s:sub(pos, pos) == '}' then
        return obj, pos + 1
    end
    while true do
        if s:sub(pos, pos) ~= '"' then
            return nil, "expected string key"
        end
        local key
        key, pos = decodeString(s, pos)
        if not key then return nil end
        pos = skipWhitespace(s, pos)
        if s:sub(pos, pos) ~= ':' then
            return nil, "expected :"
        end
        pos = skipWhitespace(s, pos + 1)
        local val
        val, pos = decodeValue(s, pos)
        if val == nil and pos == nil then return nil end
        obj[key] = val
        pos = skipWhitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = skipWhitespace(s, pos + 1)
        else
            return nil, "expected , or }"
        end
    end
end

decodeValue = function(s, pos)
    pos = skipWhitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == '"' then
        return decodeString(s, pos)
    elseif c == '{' then
        return decodeObject(s, pos)
    elseif c == '[' then
        return decodeArray(s, pos)
    elseif c == 't' then
        if s:sub(pos, pos + 3) == "true" then
            return true, pos + 4
        end
    elseif c == 'f' then
        if s:sub(pos, pos + 4) == "false" then
            return false, pos + 5
        end
    elseif c == 'n' then
        if s:sub(pos, pos + 3) == "null" then
            return nil, pos + 4
        end
    else
        local numStr = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if numStr then
            return tonumber(numStr), pos + #numStr
        end
    end
    return nil, nil
end

function Utils.jsonDecode(s)
    if not s or s == "" then return nil end
    local val = decodeValue(s, 1)
    return val
end

--------------------------------------------------------------------------------
-- JSON encode
--------------------------------------------------------------------------------

local encodeValue

local function encodeString(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function isArray(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

encodeValue = function(val)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return encodeString(val)
    elseif t == "table" then
        if isArray(val) then
            local parts = {}
            for i = 1, #val do
                parts[i] = encodeValue(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == "string" then
                    parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(v)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function Utils.jsonEncode(val)
    return encodeValue(val)
end

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
