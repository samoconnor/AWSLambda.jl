#==============================================================================#
# zip.jl
#
# ZIP utilities.
#
# Copyright Sam O'Connor 2015 - All rights reserved
#==============================================================================#


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
