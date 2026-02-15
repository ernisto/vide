export type Read<T> = (() -> T) | T

local function read<T>(value: Read<T>): T
    return if type(value) == "function" then value() else value
end

return read
