local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")
local fs_util = require("agent.lib.fs_util")
local observation = require("agent.lib.observation")

local function normalize_line_endings(text)
    return (text:gsub("\r\n", "\n"))
end

local function detect_line_endings(text)
    local crlf = 0
    for _ in text:gmatch("\r\n") do
        crlf = crlf + 1
    end
    local lf = 0
    for _ in text:gmatch("\n") do
        lf = lf + 1
    end
    lf = lf - crlf
    return crlf > lf and "CRLF" or "LF"
end

local function restore_line_endings(text, style)
    if style == "CRLF" then
        return (normalize_line_endings(text):gsub("\n", "\r\n"))
    end
    return text
end

local function count_occurrences(content, needle)
    local count = 0
    local position = 1
    while true do
        local found = content:find(needle, position, true)
        if not found then
            break
        end
        count = count + 1
        position = found + #needle
    end
    return count
end

local function replace_all(content, old_string, new_string)
    local pieces = {}
    local position = 1
    while true do
        local found, last = content:find(old_string, position, true)
        if not found then
            table.insert(pieces, content:sub(position))
            break
        end
        table.insert(pieces, content:sub(position, found - 1))
        table.insert(pieces, new_string)
        position = last + 1
    end
    return table.concat(pieces)
end

local function edit(parameters)
    assert(type(parameters.file_path) == "string", "bad argument #file_path (string expected, got " .. type(parameters.file_path) .. ")")
    assert(parameters.file_path:match("%S"), "file_path must be a non-empty string")
    assert(type(parameters.old_string) == "string", "bad argument #old_string (string expected, got " .. type(parameters.old_string) .. ")")
    assert(type(parameters.new_string) == "string", "bad argument #new_string (string expected, got " .. type(parameters.new_string) .. ")")
    assert(type(parameters.replace_all) == "boolean" or parameters.replace_all == nil, "bad argument #replace_all (boolean expected, got " .. type(parameters.replace_all) .. ")")
    assert(parameters.old_string ~= "", "old_string must be a non-empty string")
    assert(parameters.old_string ~= parameters.new_string, "old_string and new_string must differ")

    local file_path = shell.resolve(parameters.file_path)
    observation.ensure_observed(file_path)

    if not fs.exists(file_path) then
        error("cannot edit \"" .. file_path .. "\": not found", 0)
    elseif fs.isDirectory(file_path) then
        error("cannot edit \"" .. file_path .. "\": not a regular file", 0)
    end

    local raw, read_reason = fs_util.read_file(file_path)
    if not raw then
        error("cannot edit \"" .. file_path .. "\": " .. tostring(read_reason), 0)
    end
    if raw:find("\0", 1, true) then
        error("cannot edit \"" .. file_path .. "\": binary file", 0)
    end

    local line_endings = detect_line_endings(raw)
    local content = normalize_line_endings(raw)
    local old_string = normalize_line_endings(parameters.old_string)
    local new_string = normalize_line_endings(parameters.new_string)
    local occurrences = count_occurrences(content, old_string)

    if occurrences == 0 then
        error("old_string was not found in \"" .. file_path .. "\"", 0)
    end
    if not parameters.replace_all and occurrences > 1 then
        error("old_string matched " .. occurrences .. " times in \"" .. file_path .. "\"; provide a more specific old_string or set replace_all to true", 0)
    end

    local updated
    if parameters.replace_all then
        updated = replace_all(content, old_string, new_string)
    else
        local found = content:find(old_string, 1, true)
        updated = content:sub(1, found - 1) .. new_string .. content:sub(found + #old_string)
    end

    local ok, write_reason = fs_util.write_file(file_path, restore_line_endings(updated, line_endings))
    if not ok then
        error("cannot edit \"" .. file_path .. "\": " .. tostring(write_reason), 0)
    end

    observation.mark(file_path)
    if parameters.replace_all then
        return "The file " .. file_path .. " has been updated. All occurrences were successfully replaced."
    end
    return "The file " .. file_path .. " has been updated successfully."
end

local info = {
    type = "function",
    ["function"] = {
        name = "edit",
        description = "Edit an existing UTF-8 text file by replacing literal text. Read the file before editing it.",
        parameters = {
            type = "object",
            properties = {
                file_path = { type = "string", description = "Path to edit, resolved by the filesystem backend. Provide `file_path` before `old_string` and `new_string` in the arguments." },
                old_string = { type = "string", description = "Literal text to replace." },
                new_string = { type = "string", description = "Literal replacement text. Use an empty string to delete the match." },
                replace_all = { type = "boolean", description = "Replace all matches. Defaults to false; when false, old_string must appear exactly once." }
            },
            required = { "file_path", "old_string", "new_string" }
        }
    }
}

registerTool(info, edit)
