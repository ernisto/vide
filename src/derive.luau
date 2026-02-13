local graph = require "./graph"
local create_node = graph.create_node
local push_parent = graph.push_parent
local assert_stable_scope = graph.assert_stable_scope
local evaluate_node = graph.evaluate_node

local function derive<T>(source: () -> T): () -> T
    local node = create_node(assert_stable_scope(), source, false :: any)

    evaluate_node(node)

    return function()
        push_parent(node)
        return if node.ok then node.cache else error(node.cache)
    end
end

return derive
