--
-- json.lua - Minimal JSON encoder/decoder for Lightroom plugins
--
-- Handles: strings, numbers, booleans, nil/null, tables (arrays + objects)
--

local JSON = {}

--------------------------------------------------------------------------------
-- Decode
--------------------------------------------------------------------------------

local function skipWhitespace(s, pos)
    return s:match("^%s*()", pos)
end

local function decodeString(s, pos)
    -- pos points to the opening quote
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

local decodeValue -- forward declaration

local function decodeArray(s, pos)
    pos = pos + 1 -- skip [
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
    pos = pos + 1 -- skip {
    pos = skipWhitespace(s, pos)
    local obj = {}
    if s:sub(pos, pos) == '}' then
        return obj, pos + 1
    end
    while true do
        -- key must be a string
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
        -- number
        local numStr = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if numStr then
            return tonumber(numStr), pos + #numStr
        end
    end
    return nil, nil
end

function JSON.decode(s)
    if not s or s == "" then return nil end
    local val, pos = decodeValue(s, 1)
    return val
end

--------------------------------------------------------------------------------
-- Encode
--------------------------------------------------------------------------------

local encodeValue -- forward declaration

local function encodeString(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return '"' .. s .. '"'
end

--- Check if a table is an array (sequential integer keys starting at 1).
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

function JSON.encode(val)
    return encodeValue(val)
end

return JSON
