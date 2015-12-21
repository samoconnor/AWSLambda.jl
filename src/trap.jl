#==============================================================================#
# trap.jl
#
# "@safe try" and @trap exception handling
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


#-------------------------------------------------------------------------------
#
# @safe try... re-writes "try_expr" to automatically rethrow()
# at end of "catch" block (unless exception has been set to nothing).
#
# @trap e if... re-writes "if_expr" to ignore exceptions thrown by the if
# "condition" and to set "exception" = nothing if the "condition" is true.
#
# e.g.
#    
#    @safe try
#
#        return s3_get(url)
#
#    catch e
#        @trap e if e.code in {"NoSuchKey", "AccessDenied"}
#            return nothing
#        end
#    end
#
#-------------------------------------------------------------------------------


macro safe(try_expr::Expr)

    @assert string(try_expr.head) == "try"

    (try_block, exception, catch_block) = try_expr.args

    @assert isa(exception, Symbol)

    # Build safe try expression...
    safe_try_expr = quote
        try
            $(esc(try_block))

        catch $(esc(exception))

            $(esc(catch_block))

            if $(esc(exception)) != nothing
                rethrow($(esc(exception)))
            end
        end
    end
end


macro trap(exception::Symbol, if_expr::Expr)

    @assert string(if_expr.head) == "if"

    (condition, action) = if_expr.args

    quote
        _trapped = false
        try
            _trapped = $(esc(condition))
        end
        if _trapped
            $(esc(action))
            $(esc(exception)) = nothing
        end
    end
end



#==============================================================================#
# End of file.
#==============================================================================#
