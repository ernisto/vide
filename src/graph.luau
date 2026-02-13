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
    cleanups: NO_SPARSE | { Node<T> | (Node<T>) -> () },

    ok: boolean,
    pending: NO_SPARSE | thread,

    context: NO_SPARSE | { [number]: unknown },

    owner: NO_SPARSE | Node<T>,

    depth: number,
    parents: { SourceNode<T> },
    [number]: Node<T> -- children
}

type scope_stack = { [number]: Node<any>, n: number }
local thread_stacks: { [thread]: scope_stack } = {}
local sync_stack: scope_stack = { n = 0 }

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

local function get_scope(): Node<unknown>?
    local stack = sync_stack.n == 0 and thread_stacks[coroutine.running()] or sync_stack
    return stack[stack.n]
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
    local stack = sync_stack.n == 0 and thread_stacks[coroutine.running()] or sync_stack
    local n = stack.n + 1
    stack.n = n
    stack[n] = node
end

local function pop_scope()
    local stack = sync_stack.n == 0 and thread_stacks[coroutine.running()] or sync_stack
    local n = stack.n
    stack.n = n - 1
    stack[n] = nil
end

local function push_cleanup<T>(node: Node<T>, cleanup: Node<T> | () -> ())
    if node.cleanups then
        table.insert(node.cleanups, cleanup)
    else
        node.cleanups = { cleanup }
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

local function flush_cleanups<T>(node: Node<T>)
    if node.pending then
        coroutine.close(node.pending)
        node.pending = NO_SPARSE
    end

    local cleanups = node.cleanups :: any
    if cleanups == NO_SPARSE then return end

    for i = #cleanups, 1, -1 do
        local fn = cleanups[i]
        if type(fn) == 'function' then 
            local ok, err = xpcall(fn, efn, node)
            if ok then continue end
            error(`cleanup error: {err}`, 0)
        end

        -- let gc cook owner/cleanups
        flush_cleanups(fn)
        unparent(fn)
        fn.owner = NO_SPARSE
    end
    node.cleanups = NO_SPARSE
end

local function destroy<T>(node: Node<T>)
    if flags.strict and table.find(sync_stack, node) then
        error("attempt to destroy an active scope", 0)
    end

    flush_cleanups(node)
    unparent(node)
    
    if node.owner == NO_SPARSE then return end
    find_and_swap_pop(node.owner.cleanups :: { Node<T> }, node)
    node.owner = NO_SPARSE
end

-- double pointer queue
local update_queue = {} :: { Node<any> | NO_SPARSE }
local evaluating_depth = 1
local head = 0
local tail = 0

local function get_update_queue_length()
    return tail
end

local function queue_children_for_update<T>(node: SourceNode<T>)
    while node[1] do
        tail += 1
        update_queue[tail] = node[1]
        unparent(node[1])
    end
end

local _update_descendants
local function handle_error(err)
    local stack = if sync_stack.n == 0 then thread_stacks[coroutine.running()] else sync_stack
    local node = stack[1]
    
    local cur_ok = node.ok
    local cur_value = node.cache
    local yielded = node.pending

    node.ok = false
    node.cache = efn(err) :: any
    node.pending = NO_SPARSE

    if node.cache == cur_value and cur_ok == false then return end
    if yielded then _update_descendants(node) else queue_children_for_update(node) end

    error(err)
end

local free_worker: thread?
local function run_node_loop<T>(node: Node<T>)
    xpcall(function()
        local worker = coroutine.running()
        while thread_stacks[worker] == nil do
            free_worker = worker

            node = nil :: any   -- enable gc
            node = coroutine.yield()
            free_worker = nil

            local cur_ok = node.ok
            local cur_value = node.cache

            local new_value = (node :: any).effect(cur_value)
            local yielded = node.pending

            node.ok = true
            node.cache = new_value
            node.pending = NO_SPARSE

            if new_value == cur_value and cur_ok == true then continue end
            if yielded then _update_descendants(node) else queue_children_for_update(node) end
        end
    end, handle_error)
end
local function new_worker()
    local thread = coroutine.create(run_node_loop)
    coroutine.resume(thread)
    return thread
end

local function run<T>(node: Node<T>)
    push_scope(node)

    local worker = free_worker or new_worker()
    coroutine.resume(worker, node)

    pop_scope()
    if free_worker == worker then return end

    thread_stacks[worker] = { n = 1, node }
    node.pending = worker
end

local function evaluate_node<T>(node: Node<T>)
    if flags.strict and table.find(sync_stack, node) then
        node.ok = false
        node.cache = efn("a scope, that should rerun due to the update of a source, is already active") :: any
        return
    end

    flush_cleanups(node)
    node.depth = if node.owner then node.owner.depth + 1 else 1

    run(node)
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
            else
                evaluate_node(node)
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
_update_descendants = update_descendants

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

        pending = NO_SPARSE,
        ok = true,

        context = NO_SPARSE,

        owner = owner,

        parents = {},
        depth = if owner then owner.depth + 1 else 1,
    }

    if owner then
        push_cleanup(owner, node)
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
    scopes = sync_stack,

    q = update_queue
}
