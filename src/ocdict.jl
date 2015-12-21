#==============================================================================#
# ocdict.jl
#
# Dictionary type utilities.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import Base.merge, Base.get


get(nothing::Void, key, default) = default


# Merge new k,v pairs into dictionary...
#
#   d = Dict("a"=>1, "b"=>2)
#   merge(d, "c"=>3, "d"=>4)
#   Dict("a"=>1,"b"=>2,"c"=>3,"d"=>4)

merge{K,V}(d::Dict{K,V}) = d
merge{K,V}(d::Dict{K,V}, p::Pair{K,V}...) = merge(d, Dict{K,V}(p))


typealias StrDict Dict{ASCIIString,ASCIIString}


# Convert keys and values to strings...
StrDict(d::Array{Any,1}) = StrDict([string(k) => string(v) for (k,v) in d])


typealias SymDict Dict{Symbol,Any}


# SymDict from keyword arguments.
#
#   symdict(a=1,b=2)
#   Dict{Symbol,Any}(:a=>1,:b=>2)

symdict(;args...) = SymDict(args)


# SymDict from local variables and keyword arguments.
#
#   a = 1
#   b = 2
#   @symdict(a,b,c=3,d=4)
#   Dict(:a=>1,:b=>2,:c=>4,:d=>4)
#
#   function f(a; args...)
#       b = 2
#       @symdict(a, b, c=3, d=0, args...)
#   end
#   f(1, d=4)
#   Dict(:a=>1,:b=>2,:c=>4,:d=>4)

macro symdict(args...)

    @assert !isa(args[1], Expr) || args[1].head != :tuple

    # Check for "args..." at end...
    extra = nothing
    if isa(args[end], Expr) && args[end].head == symbol("...")
        extra = :(SymDict($(args[end].args[1])))
        args = args[1:end-1]
    end

    # Ensure that all args are keyword arg Exprs...
    new_args = []
    for a in args
        if !isa(a, Expr)
            a = :($a=$a)
        end
        if !isa(a.args[1], Symbol)
            a.args[1] = eval(:(symbol($(a.args[1]))))
        end
        a.head = :kw
        push!(new_args, a)
    end

    if extra != nothing
        :(merge!(symdict($(new_args...)), $extra))
    else
        :(symdict($(new_args...)))
    end
end


# Merge new k,v pairs into dictionary  ..
#
#   d = symdict(a=1,b=2)
#   merge(d, c=3, d=4)
#   Dict(:a=>1,:b=>2,:c=>4,:d=>4)

merge(d::SymDict; args...) = merge(d, SymDict(args))


SymDict(d::Dict{AbstractString,Any}) = SymDict([symbol(k) => v for (k,v) in d])


using ZipFile


# Convert dictionarty to .ZIP data...

function zipdict(d::Dict{AbstractString,Any})

    io = IOBuffer()

    w = ZipFile.Writer(io);
    for (k,v) in d
        f = ZipFile.addfile(w, k, method=ZipFile.Deflate)
        write(f, v)
        close(f)
    end
    close(w)

    zip = takebuf_array(io)
    close(io)

    return zip
end


zipdict(args::Pair...) = zipdict(Dict{AbstractString,Any}(args))



#==============================================================================#
# End of file.
#==============================================================================#
