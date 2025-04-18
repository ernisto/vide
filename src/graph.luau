local flags = require "./flags"
local update_id = 0

export type SourceNode<T> = {
    cache: T,
    [number]: Node<T>
}

export type Node<T> =  {
    cache: T,
    effect:  ((T) -> T) | false,

    higher_parent_update_id: number,
    last_eval_update_id: number,

    cleanups: { () -> () } | false,
    context: { [number]: unknown } | false,

    owned: { Node<T> } | false,
    owner: Node<T> | false,

    parents: { SourceNode<T> },
    [number]: Node<T> -- children
}

local scopes = { n = 0 } :: { [number]: Node<any>, n: number } -- scopes stack

local function is_similar(a: any, b: any)
	return a == b and (type(a) ~= 'table' or table.isfrozen(a))
end

local function efn(err: string)
    local trace = debug.traceback(err, 2)

    if string.find(err, "^effect error stacktrace") then -- if effect error is nested
        trace = string.gsub("    " .. trace, "\n", function() -- indent entire error
            return "\n    "
        end)
    end

    trace ..= "\nsource update stacktrace:"
    return trace
end

local function ycall<T, U>(fn: (T) -> U, arg: T): (boolean, string|U)

    local thread = coroutine.create(xpcall)
    --local function efn(err: string) return debug.traceback(err, 3) end
    local resume_ok, run_ok, result = coroutine.resume(thread, fn, efn, arg)

    assert(resume_ok)
        
    if coroutine.status(thread) ~= "dead" then
        return false, debug.traceback(thread, "attempt to yield in reactive scope")
    end

    return run_ok, result
end

local function get_scope(): Node<unknown>?
    return scopes[scopes.n]
end

local function bump_update_id()
    update_id += 1
    return update_id
end

local function assert_stable_scope(): Node<unknown>
    local scope = get_scope()

    if not scope then
        local caller_name = debug.info(2, "n")
        return error(`cannot use {caller_name}() outside a stable or reactive scope`, 0)
    elseif scope.effect then
        error("cannot create a new reactive scope inside another reactive scope", 0)
    end

    return scope
end

local function push_child<T>(parent: SourceNode<any>, child: Node<any>)
    table.insert(parent, child)
    table.insert(child.parents, parent)
end

local function push_scope<T>(node: Node<T>)
    local n = scopes.n + 1
    scopes.n = n
    scopes[n] = node
end

local function pop_scope()
    local n = scopes.n
    scopes.n = n - 1
    scopes[n] = nil
end

local function push_cleanup<T>(node: Node<T>, cleanup: () -> ())
    if node.cleanups then
        table.insert(node.cleanups, cleanup)
    else
        node.cleanups = { cleanup }
    end
end

local function flush_cleanups<T>(node: Node<T>)
    if node.cleanups then
        for _, fn in next, node.cleanups do
            local ok, err: string? = xpcall(fn, debug.traceback)
            if not ok then error(`cleanup error: {err}`, 0) end
        end

        table.clear(node.cleanups)
    end
end

local function find_and_swap_pop<T>(t: { T }, v: T)
    local i = table.find(t, v) :: number
    local n = #t
    t[i] = t[n]
    t[n] = nil
end

local function unparent<T>(node: Node<T>)
    local parents = node.parents

    for i, parent in parents do
        find_and_swap_pop(parent, node)
        parents[i] = nil
    end
end

local function destroy<T>(node: Node<T>)
    if flags.strict and table.find(scopes, node) then
        error("attempt to destroy an active scope", 0)
    end

    flush_cleanups(node)
    unparent(node)
    
    if node.owner then
        find_and_swap_pop(node.owner.owned :: { Node<T> }, node)
        node.owner = false
    end

    if node.owned then
        local owned = node.owned
        while owned[1] do destroy(owned[1]) end
    end
end

local function destroy_owned<T>(node: Node<T>)
    if node.owned then
        local owned = node.owned
        while owned[1] do destroy(owned[1]) end
    end
end

local update_queue = { n = 0 } :: { n: number, [number]: Node<any> }
local queue_children_for_update

local function evaluate_node<T>(node: Node<T>)
    if node.higher_parent_update_id == node.last_eval_update_id then return end
    node.last_eval_update_id = update_id

    local cur_value = node.cache

    flush_cleanups(node)
    destroy_owned(node)

    push_scope(node)
    local ok, new_value = (if flags.strict then ycall else pcall :: any)(node.effect :: (T) -> T, node.cache)
    pop_scope()

    if not ok then
        table.clear(update_queue)
        update_queue.n = 0
        error(`effect error:\n{new_value}`, 0)
    end

    node.cache = new_value
    if not is_similar(cur_value, new_value) then
        queue_children_for_update(node)
    end
end

function queue_children_for_update<T>(node: SourceNode<T>)
    local queue_index = update_queue.n
    local child_index = 1

    repeat
        local child = node[child_index]
        if not child then break end

        if child.last_eval_update_id == update_id then child_index += 1; continue end
        child.higher_parent_update_id = update_id

        queue_index += 1
        update_queue[queue_index] = child
        unparent(child)
    until false

    update_queue.n = queue_index
end

local function get_update_queue_length()
    return update_queue.n
end

local function flush_update_queue(from: number)
    local i = from + 1
    while i <= update_queue.n do
        local node = update_queue[i]
        --assert(node.effect)

        if node.owner then evaluate_node(node) end

        update_queue[i] = false :: any
        i += 1
    end
    
    update_queue.n = from
end

local function update_descendants<T>(root: SourceNode<T>)
    local n0 = update_queue.n
    queue_children_for_update(root)

    if flags.batch then return end
    flush_update_queue(n0)
end

local function push_child_to_scope<T>(node: SourceNode<T>)
    local scope = get_scope()
    if scope and scope.effect then -- do not track nodes with no effect
        push_child(node, scope)
    end
end

local function create_node<T>(owner: false | Node<any>, effect: false | (T) -> T, value: T): Node<T>
    local node: Node<T> = {
        cache = value,
        effect = effect,
        cleanups = false,
        context = false,

        higher_parent_update_id = update_id,
        last_eval_update_id = -1,

        owner = owner,
        owned = false,

        parents = {},
    }

    if owner then
        if owner.owned then
            table.insert(owner.owned, node)
        else
            owner.owned = { node }
        end
    end

    return node
end

local function create_source_node<T>(value: T): SourceNode<T>
    return { cache = value }
end

local function get_children<T>(node: Node<T>): { Node<unknown> }
    return { unpack(node) } :: { Node<any> }
end

local function set_context<T>(node: Node<T>, key: number, value: unknown)
    if node.context then
        node.context[key] = value
    else
        node.context = { [key] = value }
    end
end

return table.freeze {
    push_scope = push_scope,
    pop_scope = pop_scope,
    evaluate_node = evaluate_node,
    get_scope = get_scope,
    assert_stable_scope = assert_stable_scope,
    push_cleanup = push_cleanup,
    destroy = destroy,
    flush_cleanups = flush_cleanups,
    push_child_to_scope = push_child_to_scope,
    update_descendants = update_descendants,
    push_child = push_child,
    create_node = create_node,
    create_source_node = create_source_node,
    get_children = get_children,
    flush_update_queue = flush_update_queue,
    get_update_queue_length = get_update_queue_length,
    set_context = set_context,
    bump_update_id = bump_update_id,
    scopes = scopes,

    q = update_queue
}
