#==============================================================================#
# xml.jl
#
# XML parsing utilities
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import LightXML: LightXML, XMLDocument, XMLElement, root, name,
                 child_elements, get_elements_by_tagname, content

XML(s::AbstractString) = LightXML.parse_string(s)
XML(s::Array{UInt8,1}) = XML(bytestring(s))
XML(r::Response) = XML(r.data)

has_child_elements(e::XMLElement) = length(collect(child_elements(e))) > 0

function Base.getindex(e::XMLElement, tag::AbstractString)

    l = get_elements_by_tagname(e, tag)
    if l == nothing || has_child_elements(l[1])
        return l
    else
        l = [strip(content(i)) for i in l]
        return all(i -> i == "", l) ? nothing : l
    end
end


function Base.getindex(a::Array{XMLElement,1}, tag::AbstractString)

    vcat([e[tag] for e in a]...)
end


Base.getindex(d::XMLDocument, tag::AbstractString) = LightXML.root(d)[tag]


function Base.getindex(a::Array{XMLElement,1},
                       n::AbstractString, v::AbstractString)

    [e[n][1] => e[v][1] for e in a]
end



#==============================================================================#
# End of file.
#==============================================================================#
