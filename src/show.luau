local read = require "./read"
local source = require "./source"
local derive = require "./derive"
local effect = require "./effect"
local switch = require "./switch"

type Array<T> = { T }
type Source<T> = () -> T

type ReadSafeComponent<I, O> = ((Source<I>, Source<boolean>) -> (O, ...number)) | O

local function show<T, Obj>(
    input: read.Read<T?>,
    component: ReadSafeComponent<T, Obj>,
    fallback: switch.ReadComponent<Obj>?
): Source<nil | Obj | Array<Obj>>
    local filtered_input = source()

    effect(function()
        local v = read(input) 
        if v then filtered_input(v) end
    end)

    local input_is_truthy = derive(function()
        return not not read(input)
    end)

    return switch(input_is_truthy) {
        [true] = if type(component) ~= 'function' then component
            else function(present)
                return component(filtered_input, present)
            end,
        [false] = fallback
    }
end

return show
