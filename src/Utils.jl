"""
    `tuple_collect(::Type{Union{Types...}}) -> Tuple(Types...)`
Returns a tuple of the types in a Union type.
"""
@generated function tuple_collect(::Type{U}) where {U}
    U === Union{} && return ()
    types = tuple(Base.uniontypes(U)...)
    return :($tuple($(types...)))
end