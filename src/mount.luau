local root = require "./root"
local apply = require "./apply"

local function mount<T, Arg...>(component: (Arg...) -> T?, target: Instance?,...: Arg...): () -> ()
    local args = table.pack(...)
    return root(function()
        local result = component(unpack(args :: any))
        if target then apply(target, { result }) end
    end)
end

return mount
