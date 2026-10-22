local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")
local fs_util = require("agent.lib.fs_util")
local glob = require("agent.lib.glob")
local regex = require("agent.lib.regex")

local MAX_MATCHES = 250
local MAX_LINE_BYTES = 2000

local function validate_include(include)
    if not include:match("%S") then
        error("include must be a non-empty glob when given", 0)
    end
    if include:sub(1, 1) == "!" then
        error("include must be a positive glob filter; negated patterns (\"!...\") are not supported", 0)
    end

    local depth = 0
    for index = 1, #include do
        local char = include:sub(index, index)
        if char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = math.max(0, depth - 1)
        elseif char == "," and depth == 0 then
            error("include must be one glob, not a comma-separated list (use {a,b} alternation instead)", 0)
        end
    end
end

local function search(parameters)
    assert(type(parameters.pattern) == "string", "bad argument #pattern (string expected, got " .. type(parameters.pattern) .. ")")
    assert(parameters.pattern ~= "", "pattern must be a non-empty string")
    assert(type(parameters.path) == "string" or parameters.path == nil, "bad argument #path (string expected, got " .. type(parameters.path) .. ")")
    assert(type(parameters.include) == "string" or parameters.include == nil, "bad argument #include (string expected, got " .. type(parameters.include) .. ")")
    if parameters.path ~= nil then
        assert(parameters.path:match("%S"), "path must be a non-empty string when given")
    end
    if parameters.include ~= nil then
        validate_include(parameters.include)
    end

    local matcher, regex_reason = regex.new(parameters.pattern)
    if not matcher then
        error("invalid regular expression: " .. tostring(regex_reason), 0)
    end

    local include
    if parameters.include ~= nil then
        local include_reason
        include, include_reason = glob.new(parameters.include)
        if not include then
            error("invalid include glob: " .. tostring(include_reason), 0)
        end
    end

    local root = shell.resolve(parameters.path or ".")
    if not fs.exists(root) then
        error("cannot search \"" .. root .. "\": not found", 0)
    end

    local matches = {}
    local truncated = false

    local function search_file(absolute, relative, name)
        local display = fs_util.display_path(absolute)
        if include and not (glob.match(include, relative, name, absolute)
                or glob.match(include, display, name, absolute)) then
            return false
        end

        local file = io.open(absolute, "r")
        if not file then
            return false
        end

        local file_matches = {}
        local line_number = 0
        local binary = false
        local ok, search_error = pcall(function()
            while true do
                local line, read_reason = file:read("*l")
                if not line then
                    if read_reason then
                        binary = true
                    end
                    break
                end
                line_number = line_number + 1
                if line:find("\0", 1, true) then
                    binary = true
                    break
                end
                if matcher(line) then
                    local preview, cut = fs_util.truncate_utf8(line, MAX_LINE_BYTES)
                    if cut then
                        preview = preview .. " (line truncated)"
                    end
                    table.insert(file_matches, { line = line_number, text = preview })
                    if #matches + #file_matches >= MAX_MATCHES then
                        truncated = true
                        break
                    end
                end
            end
        end)
        file:close()
        if not ok then
            error(search_error, 0)
        end

        if not binary then
            for _, match in ipairs(file_matches) do
                if #matches >= MAX_MATCHES then
                    truncated = true
                    break
                end
                table.insert(matches, {
                    path = display,
                    line = match.line,
                    text = match.text
                })
            end
        end
        return truncated
    end

    local ok, walk_reason = fs_util.walk_files(root, {
        include_hidden = false,
        exclude_vcs = true
    }, search_file)
    if not ok then
        error("cannot search \"" .. root .. "\": " .. tostring(walk_reason), 0)
    end

    if #matches == 0 then
        return "No matches found"
    end

    local order = {}
    local groups = {}
    for _, match in ipairs(matches) do
        local group = groups[match.path]
        if not group then
            group = {}
            groups[match.path] = group
            table.insert(order, match.path)
        end
        table.insert(group, match)
    end

    local sections = {}
    for _, path in ipairs(order) do
        local lines = { path }
        for _, match in ipairs(groups[path]) do
            table.insert(lines, "Line " .. match.line .. ": " .. match.text)
        end
        table.insert(sections, table.concat(lines, "\n"))
    end

    local noun = #matches == 1 and "match" or "matches"
    local result = "Found " .. #matches .. " " .. noun .. "\n\n" .. table.concat(sections, "\n\n")
    if truncated then
        result = result .. "\n\n(Showing the first " .. #matches
            .. " matches; narrow pattern, path, or include to see more.)"
    end
    return result
end

local info = {
    type = "function",
    ["function"] = {
        name = "grep",
        description = "Search file contents with a regular expression. Returns matching lines with line numbers, grouped by file. "
            .. "Returns up to " .. MAX_MATCHES .. " matches; a larger result reports that it was truncated.",
        parameters = {
            type = "object",
            properties = {
                pattern = { type = "string", description = "Regular expression to search for. Common ripgrep syntax (including (?i)) is supported; lookaround and backreferences are not." },
                path = { type = "string", description = "File or directory to search. Defaults to the current working directory; a relative path resolves against it." },
                include = { type = "string", description = "One glob filter for which files to search (e.g. \"*.ts\", \"*.{js,jsx}\"). Not a list; negation is not supported." }
            },
            required = { "pattern" }
        }
    }
}

registerTool(info, search)
