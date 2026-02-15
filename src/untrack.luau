local read = require "./read"
local graph = require "./graph"
type Node<T> = graph.Node<T>
local get_scope = graph.get_scope

local function untrack<T>(source: read.Read<T>): T
    if type(source) ~= 'function' then return source end

    local scope = get_scope()
    if not scope then return source() end

    -- sources are only tracked if the node in scope has an effect
    local effect = scope.effect
    scope.effect = false

    local ok, result = xpcall(source, debug.traceback)
    scope.effect = effect :: () -> ()

    if not ok then error(result, 0) end
    return result :: T
end

return untrack :: ( <T>(fn: () -> T) -> T ) & ( (fn: () -> ()) -> () )
