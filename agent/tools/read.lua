local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")
local fs_util = require("agent.lib.fs_util")
local observation = require("agent.lib.observation")

local MAX_READ_LINES = 2000

local function read(parameters)
    assert(type(parameters.file_path) == "string", "bad argument #file_path (string expected, got " .. type(parameters.file_path) .. ")")
    assert(parameters.file_path:match("%S"), "file_path must be a non-empty string")

    local offset = parameters.offset
    local limit = parameters.limit
    if offset == nil then
        offset = 1
    end
    if limit == nil then
        limit = MAX_READ_LINES
    end
    assert(type(offset) == "number", "bad argument #offset (number expected, got " .. type(offset) .. ")")
    assert(type(limit) == "number", "bad argument #limit (number expected, got " .. type(limit) .. ")")
    assert(offset >= 1 and offset < math.huge and offset == math.floor(offset), "offset must be a positive integer")
    assert(limit >= 1 and limit < math.huge and limit == math.floor(limit), "limit must be a positive integer")

    local file_path = shell.resolve(parameters.file_path)
    if not fs.exists(file_path) then
        error("cannot read \"" .. file_path .. "\": not found", 0)
    elseif fs.isDirectory(file_path) then
        error("cannot read \"" .. file_path .. "\": not a regular file", 0)
    end

    local lines, read_reason = fs_util.read_lines(file_path, offset, limit)
    if not lines then
        error("cannot read \"" .. file_path .. "\": " .. tostring(read_reason or "cannot read file"), 0)
    end
    observation.mark(file_path)

    local output = {
        "<path>" .. file_path .. "</path>",
        "<type>file</type>",
        "<content>",
    }
    for _, line in ipairs(lines) do
        table.insert(output, line.number .. ": " .. line.text)
    end
    table.insert(output, "</content>")
    return table.concat(output, "\n")
end

local info = {
    type = "function",
    ["function"] = {
        name = "read",
        description = "Read a UTF-8 text file and return line-numbered content.",
        parameters = {
            type = "object",
            properties = {
                file_path = { type = "string", description = "Path to read, resolved by the filesystem backend." },
                offset = { type = "number", description = "1-based first line to return. Defaults to 1." },
                limit = { type = "number", description = "Maximum number of lines to return. Defaults to " .. MAX_READ_LINES .. "." }
            },
            required = { "file_path" }
        }
    }
}

registerTool(info, read)
