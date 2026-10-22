-- Cross-tool observation state. read marks a file as observed; edit and
-- overwrite-write require that mark. Successful writes and edits also mark the
-- resulting content so follow-up edits do not need another read.

local fs = require("filesystem")
local shell = require("shell")

local observation = {}
local observed = {}

local function key(path)
    local resolved = shell.resolve(path)
    local real = fs.realPath(resolved)
    return real or resolved
end

function observation.mark(path)
    observed[key(path)] = true
end

function observation.is_observed(path)
    return observed[key(path)] == true
end

function observation.ensure_observed(path)
    local resolved = key(path)
    if not observed[resolved] then
        error('cannot modify "' .. resolved .. '": file has not been read; read the file, then retry', 0)
    end
end

return observation
