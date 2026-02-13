local flags = require "./flags"

type NO_SPARSE = false  -- represents nil, but is actually `false` to dont sparse the table
local NO_SPARSE: NO_SPARSE = false

export type SourceNode<T> = {
    cache: T,
    depth: number,
    [number]: Node<T>
}

export type Node<T> =  {
    cache: T,
    effect: NO_SPARSE | (T) -> T,
    cleanups: NO_SPARSE | { () -> () },

    context: NO_SPARSE | { [number]: unknown },

    owned: NO_SPARSE | { Node<T> },
    owner: NO_SPARSE | Node<T>,

    depth: number,
    parents: { SourceNode<T> },
    [number]: Node<T> -- children
}

local scopes = { n = 0 } :: { [number]: Node<any>, n: number } -- scopes stack

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

local function assert_stable_scope(): Node<unknown>
    local scope = get_scope()

    if not scope then
        local caller_name = debug.info(2, "n")
        return error(`cannot use {caller_name}() outside a stable or reactive scope`, 0)
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
        for _, fn in node.cleanups do
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

local function unparent<T>(child: Node<T>)
    local parents = child.parents

    for i, parent in parents do
        find_and_swap_pop(parent, child)
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

-- double pointer queue
local update_queue = {} :: { Node<any> | NO_SPARSE }
local evaluating_depth = 1
local head = 0
local tail = 0

local function evaluate_node<T>(node: Node<T>)
    if flags.strict and table.find(scopes, node) then
        evaluating_depth = 1
        tail = 0
        head = 0
        error("a scope, that should rerun due to the update of a source, is already active", 0)
    end
    local cur_value = node.cache
    node.depth = if node.owner then node.owner.depth + 1 else 1

    flush_cleanups(node)
    destroy_owned(node)
    
    push_scope(node)
    local ok, new_value = (if flags.strict then ycall else pcall :: any)(node.effect :: (T) -> T, cur_value)
    pop_scope()
    
    if not ok then
        evaluating_depth = 1
        tail = 0
        head = 0
        error(`effect error stacktrace\n{new_value :: string}`, 0)
    end

    node.cache = new_value :: T
    return cur_value ~= new_value
end

local function queue_children_for_update<T>(node: SourceNode<T>)
    while node[1] do
        tail += 1
        update_queue[tail] = node[1]
        unparent(node[1])
    end
end

local function get_update_queue_length()
    return tail
end

local function flush_update_queue(from: number)
    if from == tail then return end

    local prev_depth = evaluating_depth
    local prev_head = head

    local depth_end = tail
    head = from + 1

    while head <= tail do
        if depth_end < head then
            evaluating_depth += 1
            depth_end = tail
        end

        local node = update_queue[head] :: Node<any>
        if node and node.owner then
            if node.depth > evaluating_depth then
                tail += 1
                update_queue[tail] = node
            elseif evaluate_node(node) then
                queue_children_for_update(node)
            end
        end

        update_queue[head] = NO_SPARSE
        head += 1
    end

    evaluating_depth = prev_depth
    head = prev_head
    tail = from
end

local function update_descendants<T>(root: SourceNode<T>)
    local from = tail
    queue_children_for_update(root)

    if flags.batch then return end
    flush_update_queue(from)
end

local function push_parent<T>(parent: SourceNode<T>)
    local scope = get_scope()
    if scope == nil or scope.effect == NO_SPARSE then return end

    if scope.depth <= parent.depth then
        scope.depth = parent.depth+1
        if evaluating_depth <= parent.depth then
            flush_update_queue(head)
        end
    end
    push_child(parent, scope)
end

local function create_node<T>(owner: NO_SPARSE | Node<any>, effect: NO_SPARSE | (T) -> T, value: T): Node<T>
    local node: Node<T> = {
        cache = value,
        effect = effect,
        cleanups = NO_SPARSE,

        context = NO_SPARSE,

        owner = owner,
        owned = NO_SPARSE,

        parents = {},
        depth = if owner then owner.depth + 1 else 1,
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
    return { depth = 0, cache = value }
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
    push_parent = push_parent,
    update_descendants = update_descendants,
    push_child = push_child,
    create_node = create_node,
    create_source_node = create_source_node,
    get_children = get_children,
    flush_update_queue = flush_update_queue,
    get_update_queue_length = get_update_queue_length,
    set_context = set_context,
    scopes = scopes,

    q = update_queue
}
