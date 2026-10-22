local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")
local fs_util = require("agent.lib.fs_util")
local observation = require("agent.lib.observation")

local function write(parameters)
    assert(type(parameters.file_path) == "string", "bad argument #file_path (string expected, got " .. type(parameters.file_path) .. ")")
    assert(parameters.file_path:match("%S"), "file_path must be a non-empty string")
    assert(type(parameters.content) == "string", "bad argument #content (string expected, got " .. type(parameters.content) .. ")")

    local file_path = shell.resolve(parameters.file_path)
    if fs.isDirectory(file_path) then
        error("cannot write \"" .. file_path .. "\": not a regular file", 0)
    end

    local existed = fs.exists(file_path)
    if existed then
        observation.ensure_observed(file_path)
    end

    local parent_ok, parent_reason = fs_util.ensure_dir(fs_util.parent_dir(file_path))
    if not parent_ok then
        error("cannot write \"" .. file_path .. "\": " .. tostring(parent_reason), 0)
    end

    local ok, reason = fs_util.write_file(file_path, parameters.content)
    if not ok then
        error("cannot write \"" .. file_path .. "\": " .. tostring(reason), 0)
    end

    observation.mark(file_path)
    local verb = existed and "Updated" or "Created"
    return "<path>" .. file_path .. "</path>\n<type>file</type>\n<content>\n" .. verb .. " file\n</content>"
end

local info = {
    type = "function",
    ["function"] = {
        name = "write",
        description = "Create or fully replace a UTF-8 text file. Read an existing file before overwriting it.",
        parameters = {
            type = "object",
            properties = {
                file_path = { type = "string", description = "Path to write, resolved by the filesystem backend. Provide `file_path` before `content` in the arguments." },
                content = { type = "string", description = "Full UTF-8 text content to write." }
            },
            required = { "file_path", "content" }
        }
    }
}

registerTool(info, write)
