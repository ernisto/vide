local read = require "./read"
local branch = require "./branch"
local source = require "./source"
local effect = require "./effect"
local timeout = require "./timeout" ()

type Array<T> = { T }
type Map<K, V> = { [K]: V }
type Source<T> = () -> T
export type ReadComponent<T> = ((Source<boolean>) -> (T, ...number)) | T?

local function switch_map<K, Obj>(
    input: read.Read<K>,
    map: Map<K, ReadComponent<Obj>>
): Source<nil | Obj | Array<Obj>>
    local scopes = {} :: Map<K, {
        destroy: () -> (),
        object: Obj,
        delay: number,
        present: (boolean?) -> boolean,
        timeout: { cancel: boolean }?
    }>

    local output = source(nil :: nil | Obj | Array<Obj>)
    local function update_output()
        local objects = {}

        for _, scope in scopes do
            table.insert(objects, scope.object)
        end

        output(
            if objects[2] then objects
            elseif objects[1] then objects[1]
            else nil
        )
    end

    effect(function()
        local key: K? = read(input)

        -- destroy (or queue destroy) all scopes not associated with the input key
        for k, scope in scopes do
            if k == key then continue end

            scope.present(false)

            if scope.delay == 0 then
                scope.destroy()
                scopes[k] = nil
            else
                if scope.timeout == nil then
                    scope.timeout = timeout(scope.delay, function()
                        scope.destroy()
                        scopes[k] = nil
                        update_output()
                    end)
                end
            end
        end

        -- create new scope or abort destruction of existing scope if key exists
        if key ~= nil then
            local scope = scopes[key]

            if scope then
                scope.present(true)

                if scope.timeout then
                    scope.timeout.cancel = true
                    scope.timeout = nil
                end
            else
                local component = map[key]

                if component ~= nil then
                    local present = source(false)

                    local delay = nil :: number?
                    local destroy, object = branch(function()
                        if type(component) ~= 'function' then return component end

                        local object, t = component(present)
                        delay = t
                        return object
                    end)

                    present(true)

                    scopes[key] = {
                        destroy = destroy,
                        object = object,
                        delay = delay or 0,
                        present = present,
                        timeout = nil
                    }
                end
            end
        end

        update_output()
    end)

    return output
end

local function switch<K, Obj>(input: read.Read<K>): (map: Map<K, ReadComponent<Obj>>) -> Source<nil | Obj | Array<Obj>>
    return function(map)
        return switch_map(input, map)
    end
end

return switch
