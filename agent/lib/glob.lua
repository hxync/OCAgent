-- Glob matching for OpenOS paths.
--
-- Supported syntax: *, ?, **, [...], [!...] / [^...], {a,b}, and backslash
-- escapes. A pattern without "/" matches the basename at any depth; a pattern
-- with "/" matches the path relative to the search root.

local glob = {}

local MAX_EXPANSIONS = 64

local function split_path(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    return parts
end

local function escape_lua_literal(char)
    if char:match("[%^%$%(%)%%%.%[%]%+%-%*%?]") then
        return "%" .. char
    end
    return char
end

local function escape_lua_class_char(char)
    if char == "%" then
        return "%%"
    elseif char == "]" then
        return "%]"
    end
    return char
end

local function compile_segment(segment)
    local out = { "^" }
    local i = 1
    while i <= #segment do
        local char = segment:sub(i, i)
        if char == "*" then
            table.insert(out, ".*")
            i = i + 1
        elseif char == "?" then
            table.insert(out, ".")
            i = i + 1
        elseif char == "[" then
            local j = i + 1
            local class = { "[" }
            local first = segment:sub(j, j)
            if first == "!" or first == "^" then
                table.insert(class, "^")
                j = j + 1
            end
            if segment:sub(j, j) == "]" then
                table.insert(class, "%]")
                j = j + 1
            end
            local closed = false
            while j <= #segment do
                local char_in_class = segment:sub(j, j)
                if char_in_class == "]" then
                    closed = true
                    j = j + 1
                    break
                elseif char_in_class == "\\" and j < #segment then
                    table.insert(class, escape_lua_class_char(segment:sub(j + 1, j + 1)))
                    j = j + 2
                else
                    table.insert(class, escape_lua_class_char(char_in_class))
                    j = j + 1
                end
            end
            if closed then
                table.insert(out, table.concat(class) .. "]")
                i = j
            else
                error("unterminated character class in glob pattern", 0)
            end
        elseif char == "\\" and i < #segment then
            table.insert(out, escape_lua_literal(segment:sub(i + 1, i + 1)))
            i = i + 2
        else
            table.insert(out, escape_lua_literal(char))
            i = i + 1
        end
    end
    table.insert(out, "$")
    return table.concat(out)
end

local function find_brace(pattern)
    local i = 1
    while i <= #pattern do
        local char = pattern:sub(i, i)
        if char == "\\" then
            i = i + 2
        elseif char == "{" then
            local depth = 1
            local j = i + 1
            while j <= #pattern do
                local inner = pattern:sub(j, j)
                if inner == "\\" then
                    j = j + 2
                elseif inner == "{" then
                    depth = depth + 1
                    j = j + 1
                elseif inner == "}" then
                    depth = depth - 1
                    if depth == 0 then
                        return i, j
                    end
                    j = j + 1
                else
                    j = j + 1
                end
            end
            return nil
        else
            i = i + 1
        end
    end
    return nil
end

local function split_top_level(body)
    local parts = {}
    local start = 1
    local depth = 0
    local i = 1
    while i <= #body do
        local char = body:sub(i, i)
        if char == "\\" then
            i = i + 2
        elseif char == "{" then
            depth = depth + 1
            i = i + 1
        elseif char == "}" then
            if depth > 0 then
                depth = depth - 1
            end
            i = i + 1
        elseif char == "," and depth == 0 then
            table.insert(parts, body:sub(start, i - 1))
            start = i + 1
            i = i + 1
        else
            i = i + 1
        end
    end
    table.insert(parts, body:sub(start))
    return parts
end

local function expand_braces(pattern)
    local results = {}

    local function expand(current, depth)
        if depth > 16 or #results >= MAX_EXPANSIONS then
            error("glob pattern expands to too many alternatives", 0)
        end
        local open_at, close_at = find_brace(current)
        if not open_at then
            table.insert(results, current)
            return
        end
        local body = current:sub(open_at + 1, close_at - 1)
        local parts = split_top_level(body)
        if #parts < 2 then
            table.insert(results, current)
            return
        end
        local prefix = current:sub(1, open_at - 1)
        local suffix = current:sub(close_at + 1)
        for _, part in ipairs(parts) do
            expand(prefix .. part .. suffix, depth + 1)
        end
    end

    expand(pattern, 0)
    return results
end

local function compile_alternative(pattern)
    local absolute = pattern:sub(1, 1) == "/"
    local has_slash = pattern:find("/", 1, true) ~= nil

    pattern = pattern:gsub("^%./+", "")
    if absolute then
        pattern = pattern:gsub("^/+", "")
    end
    pattern = pattern:gsub("/+$", "")

    local segments = {}
    for _, part in ipairs(split_path(pattern)) do
        if part == "**" then
            table.insert(segments, { double = true })
        else
            table.insert(segments, { pattern = compile_segment(part) })
        end
    end

    return {
        segments = segments,
        absolute = absolute,
        has_slash = has_slash,
        source = pattern,
    }
end

local function match_segments(segments, segment_index, path_segments, path_index, memo)
    local key = segment_index .. ":" .. path_index
    local cached = memo[key]
    if cached ~= nil then
        return cached
    end

    local result
    if segment_index > #segments then
        result = path_index > #path_segments
    else
        local segment = segments[segment_index]
        if segment.double then
            result = false
            for next_index = path_index, #path_segments + 1 do
                if match_segments(segments, segment_index + 1, path_segments, next_index, memo) then
                    result = true
                    break
                end
            end
        elseif path_index > #path_segments then
            result = false
        elseif path_segments[path_index]:find(segment.pattern) then
            result = match_segments(segments, segment_index + 1, path_segments, path_index + 1, memo)
        else
            result = false
        end
    end

    memo[key] = result
    return result
end

local function matches_alternative(alternative, rel_path, basename, abs_path)
    local target
    if alternative.absolute then
        target = abs_path or ("/" .. rel_path)
    elseif alternative.has_slash then
        target = rel_path
    else
        target = basename
    end
    target = target:gsub("^%./+", "")
    local path_segments = split_path(target)
    return match_segments(alternative.segments, 1, path_segments, 1, {})
end

function glob.new(pattern)
    if type(pattern) ~= "string" or pattern == "" then
        return nil, "glob pattern must be a non-empty string"
    end

    local ok, alternatives = pcall(function()
        local expanded = expand_braces(pattern)
        local compiled = {}
        for _, item in ipairs(expanded) do
            table.insert(compiled, compile_alternative(item))
        end
        return compiled
    end)
    if not ok then
        return nil, alternatives
    end
    return { alternatives = alternatives }
end

function glob.match(compiled, rel_path, basename, abs_path)
    rel_path = rel_path or ""
    if basename == nil then
        basename = rel_path:match("[^/]*$") or rel_path
    end
    for _, alternative in ipairs(compiled.alternatives) do
        if matches_alternative(alternative, rel_path, basename, abs_path) then
            return true
        end
    end
    return false
end

return glob
