local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")
local fs_util = require("agent.lib.fs_util")
local glob = require("agent.lib.glob")

local MAX_RESULTS = 100

local function find_files(parameters)
    assert(type(parameters.pattern) == "string", "bad argument #pattern (string expected, got " .. type(parameters.pattern) .. ")")
    assert(parameters.pattern:match("%S"), "pattern must be a non-empty string")
    assert(type(parameters.path) == "string" or parameters.path == nil, "bad argument #path (string expected, got " .. type(parameters.path) .. ")")
    if parameters.path ~= nil then
        assert(parameters.path:match("%S"), "path must be a non-empty string when given")
    end

    local root = shell.resolve(parameters.path or ".")
    if not fs.exists(root) then
        error("cannot search \"" .. root .. "\": not found", 0)
    end

    local compiled, pattern_reason = glob.new(parameters.pattern)
    if not compiled then
        error("invalid glob pattern: " .. tostring(pattern_reason), 0)
    end

    local found = {}
    local ok, walk_reason = fs_util.walk_files(root, {
        include_hidden = true,
        exclude_vcs = true
    }, function(absolute, relative, name)
        if glob.match(compiled, relative, name, absolute) then
            table.insert(found, {
                path = fs_util.display_path(absolute),
                modified = fs_util.last_modified(absolute) or 0
            })
        end
    end)
    if not ok then
        error("cannot search \"" .. root .. "\": " .. tostring(walk_reason), 0)
    end

    table.sort(found, function(left, right)
        if left.modified == right.modified then
            return left.path < right.path
        end
        return left.modified > right.modified
    end)

    if #found == 0 then
        return "No files found"
    end

    local lines = {}
    local shown = math.min(#found, MAX_RESULTS)
    for index = 1, shown do
        lines[index] = found[index].path
    end
    local result = table.concat(lines, "\n")
    if #found > shown then
        result = result .. "\n\n(Showing " .. shown .. " of " .. #found
            .. " paths in modification-time order; narrow pattern or path to see more.)"
    end
    return result
end

local info = {
    type = "function",
    ["function"] = {
        name = "glob",
        description = "Find files, not directories, whose paths match a glob pattern, including hidden files. "
            .. "Returns up to " .. MAX_RESULTS .. " paths in modification-time order; a larger result keeps the first paths "
            .. "and reports how many were found.",
        parameters = {
            type = "object",
            properties = {
                pattern = {
                    type = "string",
                    description = "Glob pattern to match file paths against (e.g. \"**/*.ts\", \"src/**/*.test.js\"). "
                        .. "A pattern with no \"/\" matches the basename at any depth, so \"*\" and \"*.ts\" both search the whole tree; include a separator to anchor the depth."
                },
                path = { type = "string", description = "Directory to search in. Defaults to the current working directory; a relative path resolves against it." }
            },
            required = { "pattern" }
        }
    }
}

registerTool(info, find_files)
