#==============================================================================#
# retry.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


#------------------------------------------------------------------------------#
#
# Rewrite "try_expr" to try again "max" times.
#
# e.g.
#
#    @with_retry_limit 4 try 
#
#        http_get(url)
#
#    catch e
#        if (typeof(e) == UVError)
#            @retry
#        end
#    end
#
#------------------------------------------------------------------------------#


macro with_retry_limit(max::Integer, try_expr::Expr)

    @assert string(try_expr.head) == "try"

    # Split try_expr into component parts...
    (try_block, exception, catch_block) = try_expr.args

    # Insert a rethrow() at the end of the catch_block...
    push!(catch_block.args, :($exception == nothing || rethrow($exception)))

    # Build retry expression...
    retry_expr = quote

        # Loop one less than "max" times...
        for i in [1 : $max - 1]

            # Execute the "try_expr"...
            # (It can "continue" if it wants to try again)
            $(esc(try_expr))

            # Only get to here if "try_expr" executed cleanly...
            return
        end

        # On the last of "max" attempts, execute the "try_block" naked
        # so that exceptions get thrown up the stack...
        $(esc(try_block))
    end
end


# "@retry" keyword...

macro retry() :(continue) end



#==============================================================================#
# End of file.
#==============================================================================#
