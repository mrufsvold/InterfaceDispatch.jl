macro duck_dispatch(ex)
    return duck_dispatch_logic(ex)
end

function duck_dispatch_logic(ex)
    f = JLFunction(ex)

    func_args = FuncArg.(f.args)

    arg_count = length(f.args)
    anys = tuple((Any for _ in f.args)...)
    untyped_args = tuple((get_name(func_arg) for func_arg in func_args)...)
    user_args_with_guise_check = arg_with_guise_wrap_check.(func_args)
    pushfirst!(user_args_with_guise_check, :(::$DispatchedOnDuckType))

    f.args = user_args_with_guise_check
    f_name = esc(f.name)
    user_func = esc(codegen_ast(f))

    return quote
        # We can't get typeof() on a function that hasn't been defined yet
        # so first we make sure the name exists
        function $f_name end

        # Here we will check to make sure there isn't already a normal function that would
        # be overwritten by the ducktype fallback method
        if $hasmethod($f_name, $anys) &&
           any(map($is_duck_dispatched, $methods($f_name), Iterators.repeated($arg_count)))
            error("can't overwrite " * string($f_name))
        end

        # Core.@__doc__
        $user_func

        const duck_sigs = tuple(
            $filter!(is_dispatched_on_ducktype, $extract_sig_type.($methods($f_name)))...
        )

        function (f::typeof($f_name))($(untyped_args...); kwargs...)
            wrapped_args = wrap_args(duck_sigs, tuple($(untyped_args...)))
            return @inline f($DispatchedOnDuckType(), wrapped_args...; kwargs...)
        end
    end
end

"""
    get_methods(::Type{F})
Returns the list of DuckType methods that are implemented for the function `F`.
"""
function get_methods(::Type{F}) where {F}
    return ()
end

function wrap_with_guise(target_type::Type{T}, arg) where {T}
    DuckT = if T <: DuckType
        target_type
    elseif T <: Guise
        get_duck_type(target_type)
    else
        return arg
    end
    return wrap(DuckT, arg)
end

function is_duck_dispatched(m::Method, arg_count)
    sig_types = fieldtypes(m.sig)
    # the signature will have Tuple{typeof(f), DispatchedOnDuckType, arg_types...}
    length(sig_types) != 2 + arg_count && return false
    sig_types[2] != DispatchedOnDuckType && return false
    return true
end

function extract_sig_type(m::Method)
    sig = m.sig
    sig_types = fieldtypes(sig)[2:end]
    return Tuple{sig_types...}
end

function is_dispatched_on_ducktype(sig)
    return fieldtypes(sig)[1] == DispatchedOnDuckType
end

Base.@constprop :aggressive function get_arg_types(::T) where {T}
    return fieldtypes(T)
end

Base.@constprop :aggressive function wrap_args(duck_sigs, args)
    arg_types = get_arg_types(args)
    check_quacks_like = CheckQuacksLike(Tuple{arg_types...})

    # this is a tuple of bools which indicate if the method matches the input args
    quack_check_result = map(check_quacks_like, duck_sigs)

    number_of_matches = sum(quack_check_result)
    number_of_matches == 1 || error("Expected 1 matching method, got $number_of_matches")

    match_index = findfirst(quack_check_result)
    method_match = duck_sigs[match_index]
    method_types = fieldtypes(method_match)[2:end]
    wrapped_args = map(wrap_with_guise, method_types, args)
    return wrapped_args
end

function check_param_for_duck_and_wrap(T)
    if T isa Type
        return T <: DuckType ? Guise{T, <:Any} : T
    end
    if T isa TypeVar
        return T
    end
    error("Unexpected type annotation $T")
end

function arg_with_guise_wrap_check(func_arg::FuncArg)
    return @cases func_arg.type_annotation begin
        none => :($(func_arg.name)::Any)
        [symbol, expr](type_param) => :($(func_arg.name)::(($check_param_for_duck_and_wrap($type_param))))
    end
end

function length_matches(arg_types, arg_count)
    return length(fieldtypes(arg_types)) == arg_count
end