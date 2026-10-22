local registerTool = ...

local shell = require("shell")
local fs = require("filesystem")

local function working_directory(parameters)
    assert(type(parameters.cd) == "string" or parameters.cd == nil, "bad argument #cd (string expected, got " .. type(parameters.cd) .. ")")
    if parameters.cd == nil then
        return shell.getWorkingDirectory()
    end
    assert(parameters.cd ~= "", "working-directory: cd must not be empty")
    local directory = shell.resolve(parameters.cd)
    if not fs.exists(directory) or not fs.isDirectory(directory) then
        error("working-directory: directory does not exist: \"" .. parameters.cd .. "\"", 0)
    end
    local ok, reason = shell.setWorkingDirectory(directory)
    if not ok then
        error("working-directory: " .. tostring(reason), 0)
    end
    return shell.getWorkingDirectory()
end

local info = {
    type = "function",
    ["function"] = {
        name = "working_directory",
        description = "Read the current working directory, or change it with cd. Relative paths use the current directory. Existing shells and running processes keep their own directories.",
        parameters = {
            type = "object",
            properties = {
                cd = { type = "string", description = "Existing directory to enter. Omit to read the current directory." }
            }
        }
    }
}

registerTool(info, working_directory)
