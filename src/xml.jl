#==============================================================================#
# xml.jl
#
# XML parsing utilities
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import LightXML: LightXML, XMLDocument, XMLElement, root, find_element, content,
                 get_elements_by_tagname, child_elements, name

parse_xml(s) = LightXML.parse_string(s)


import Base: get

function get(e::XMLElement, name, default="")

    i = find_element(e, name)
    if i != nothing
        return content(i)
    end
    
    for e in child_elements(e)
        e = get(e, name)
        if e != nothing
            return e
        end
    end

    return default
end


get(d::XMLDocument, name, default="") = get(root(d), name, default)


function list(xdoc::XMLDocument, list_tag, item_tag, subitem_tag="")

    result = String[]

    l = find_element(root(xdoc), list_tag)
    for e in get_elements_by_tagname(l, item_tag)

        if subitem_tag != ""
            e = find_element(e, subitem_tag)
        end
        push!(result, content(e))
    end

    return result
end


function dict(xdoc::XMLDocument, list_tag, item_tag,
              name_tag = "Name", value_tag = "Value")

    result = Dict()

    l = find_element(root(xdoc), list_tag)
    for e in get_elements_by_tagname(l, item_tag)

        n = content(find_element(e, name_tag))
        v = content(find_element(e, value_tag))
        result[n] = v
    end

    return result
end



#==============================================================================#
# End of file.
#==============================================================================#
