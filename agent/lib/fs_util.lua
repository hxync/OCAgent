-- Shared filesystem helpers for the agent tools.
-- Paths are OpenOS paths (always / separated); callers resolve user paths first.

local fs = require("filesystem")
local shell = require("shell")

local fs_util = {}

local VCS_DIRS = {
    [".git"] = true,
    [".svn"] = true,
    [".hg"] = true,
    [".bzr"] = true,
    [".jj"] = true,
    [".sl"] = true,
}

function fs_util.resolve(path)
    return shell.resolve(path)
end

function fs_util.cwd()
    return shell.getWorkingDirectory()
end

function fs_util.exists(path)
    return fs.exists(path)
end

function fs_util.is_dir(path)
    return fs.isDirectory(path)
end

function fs_util.is_file(path)
    return fs.exists(path) and not fs.isDirectory(path)
end

function fs_util.size(path)
    return fs.size(path)
end

function fs_util.last_modified(path)
    return fs.lastModified(path)
end

function fs_util.basename(path)
    local name = fs.name(path)
    if name and name ~= "" then
        return name
    end
    return path
end

function fs_util.parent_dir(path)
    path = fs.canonical(path)
    if path == "/" then
        return "/"
    end
    local parent = fs.path(path)
    parent = parent:gsub("/+$", "")
    if parent == "" then
        return "/"
    end
    return parent
end

function fs_util.is_vcs_dir(name)
    return VCS_DIRS[name] == true
end

-- Relative path for display. Inside the current working directory the result
-- has no "./" prefix; outside it stays absolute.
function fs_util.display_path(path)
    path = fs.canonical(path)
    local cwd = fs.canonical(shell.getWorkingDirectory())
    if path == cwd then
        return "."
    end
    local prefix = cwd == "/" and "/" or (cwd .. "/")
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

function fs_util.ensure_dir(path)
    path = fs.canonical(path)
    if path == "/" then
        return true
    end
    if fs.exists(path) then
        if fs.isDirectory(path) then
            return true
        end
        return nil, "not a directory"
    end

    local missing = {}
    local current = path
    while current ~= "/" and not fs.exists(current) do
        table.insert(missing, 1, current)
        current = fs_util.parent_dir(current)
    end
    if current ~= "/" and not fs.isDirectory(current) then
        return nil, "parent is not a directory: " .. current
    end

    for _, directory in ipairs(missing) do
        local ok, reason = fs.makeDirectory(directory)
        if not ok and not fs.isDirectory(directory) then
            return nil, reason or ("cannot create directory " .. directory)
        end
    end
    return true
end

function fs_util.read_file(path)
    local file, reason = io.open(path, "r")
    if not file then
        return nil, reason or "cannot open file"
    end
    local content, read_reason = file:read("*a")
    file:close()
    if content == nil then
        return nil, read_reason or "cannot read file"
    end
    return content
end

-- Read a 1-based line window. Returns an array of { number, text }, or nil, reason.
function fs_util.read_lines(path, offset, limit)
    local file, reason = io.open(path, "r")
    if not file then
        return nil, reason or "cannot open file"
    end

    local lines = {}
    local last_line = offset + limit - 1
    local number = 1
    while number <= last_line do
        local line, read_reason = file:read("*l")
        if not line then
            if read_reason then
                file:close()
                return nil, read_reason
            end
            break
        end
        if number >= offset then
            table.insert(lines, { number = number, text = line })
        end
        number = number + 1
    end
    file:close()
    return lines
end

function fs_util.write_file(path, content)
    local file, reason = io.open(path, "w")
    if not file then
        return nil, reason or "cannot open file for writing"
    end
    local ok, write_reason = file:write(content)
    if not ok then
        file:close()
        return nil, write_reason or "cannot write file"
    end
    local flushed, flush_reason = file:flush()
    if not flushed then
        file:close()
        return nil, flush_reason or "cannot flush file"
    end
    local closed, close_reason = file:close()
    if closed == nil and close_reason then
        return nil, close_reason
    end
    return true
end

-- Cut a UTF-8 string at a byte budget without splitting a codepoint.
function fs_util.truncate_utf8(text, max_bytes)
    if #text <= max_bytes then
        return text, false
    end
    local cut = max_bytes
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if byte and byte >= 128 and byte < 192 then
            cut = cut - 1
        else
            break
        end
    end
    return text:sub(1, cut), true
end

-- Walk regular files below root. on_file(abs_path, rel_path, name) may return
-- true to stop the walk. Hidden entries and VCS metadata are skipped by default.
function fs_util.walk_files(root, options, on_file)
    options = options or {}
    local include_hidden = options.include_hidden == true
    local exclude_vcs = options.exclude_vcs ~= false
    local visited = {}

    local function visit(path, rel)
        local real = fs.realPath(path) or path
        if visited[real] then
            return false
        end
        visited[real] = true

        local entries = {}
        for entry in fs.list(path) do
            entry = entry:gsub("/+$", "")
            if entry ~= "" then
                table.insert(entries, entry)
            end
        end
        table.sort(entries)

        local directories = {}
        for _, entry in ipairs(entries) do
            local hidden = entry:sub(1, 1) == "."
            if (include_hidden or not hidden) and not (exclude_vcs and fs_util.is_vcs_dir(entry)) then
                local child = fs.concat(path, entry)
                local child_rel = rel == "" and entry or (rel .. "/" .. entry)
                local linked = fs.isLink and fs.isLink(child) or false
                if fs.isDirectory(child) then
                    -- Like ripgrep's default, do not follow directory symlinks.
                    if not linked then
                        table.insert(directories, { path = child, rel = child_rel })
                    end
                elseif on_file(child, child_rel, entry) then
                    return true
                end
            end
        end

        for _, directory in ipairs(directories) do
            if visit(directory.path, directory.rel) then
                return true
            end
        end
        return false
    end

    if not fs.exists(root) then
        return nil, "not found"
    end
    if fs.isDirectory(root) then
        visit(root, "")
    else
        local name = fs_util.basename(root)
        on_file(root, name, name)
    end
    return true
end

return fs_util
