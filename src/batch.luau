local flags = require "./flags"
local graph = require "./graph"

local get_update_queue_length = graph.get_update_queue_length
local flush_update_queue = graph.flush_update_queue

local function batch(setter: () -> ())
    local already_batching = flags.batch
    local from

    if not already_batching then
        flags.batch = true
        from = get_update_queue_length()
    end

    local ok, err: string? = xpcall(setter, debug.traceback)

    if not already_batching then
        flags.batch = false
        flush_update_queue(from)
    end

    if not ok then error(`error occured while batching updates: {err}`, 0) end
end

return batch
