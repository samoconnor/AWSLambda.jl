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
#    @repeat 4 try 
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


macro repeat(max::Integer, try_expr::Expr)

    @assert string(try_expr.head) == "try"

    # Split try_expr into component parts...
    (try_block, exception, catch_block) = try_expr.args

    @assert isa(exception, Symbol)

    # Build retry expression...
    retry_expr = quote

        # Loop one less than "max" times...
        for i in 1:$max

            # Execute the "try_expr"...
            # (It can "continue" if it wants to try again)
            try
                $(esc(try_block))

            catch $(esc(exception))

                # Dont' apply catch rules on last attempt...
                if i < $max
                    $(esc(catch_block))
                end

                if $(esc(exception)) != nothing
                    rethrow($(esc(exception)))
                end
            end

            # No exception!
            break
        end
    end
end


# "@retry" keyword...

macro retry() :(continue) end



#==============================================================================#
# End of file.
#==============================================================================#
