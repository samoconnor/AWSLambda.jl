#==============================================================================#
# sdb.jl
#
# SimpleDB API. See http://aws.amazon.com/documentation/simpledb/
#
# Warning: It seems that Amazon has unofficially deprecated SimpleDB
# in favour of DynamoDB. SimpleDB is still a better tool for some tasks,
# but it’s future is uncertain.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


export sdb_list_domains


sdb(aws, query) = do_request(post_request(aws, "sdb", "2009-04-15", query))


function sdb_list_domains(aws)

    r = sdb(aws, Dict("Action" => "ListDomains"))
    return r["ListDomainsResult"]["DomainName"]
end


function sdb(aws, action, domain, query::Dict = StringDict())

    sdb(aws, merge(query, Dict("Action" => action,
                               "DomainName" => domain)))
end


sdb_create_domain(aws, domain) = sdb(aws, "CreateDomain", domain)
sdb_delete_domain(aws, domain) = sdb(aws, "DeleteDomain", domain)


function sdb(aws, action, domain, item, query::Dict = Dict())

    sdb(aws, action, domain, merge(query, Dict("ItemName" => item)))
end


sdb_delete_item(aws, domain, item) = sdb(aws, "DeleteAttributes", domain, item)


function sdb_put(aws, domain, item, attributes; replace = false)

    request = Dict(AbstractString, Any)
    i = 1
    for (n, v) in attributes

        request["Attribute.$i.Name"] = n
        request["Attribute.$i.Value"] = string(v)
        request["Attribute.$i.Replace"] = replace ? "true" : "false"
        i = i + 1
    end

    sdb(aws, "PutAttributes", domain, item, request)
end


function sdb_get(aws, domain, item, attribute = "")

    request = Dict(AbstractString, Any)

    if attribute != ""
        request["AttributeName"] = attribute
    end

    r = sdb(aws, "GetAttributes", domain, item, request)

    r = r["GetAttributesResult"]["Attribute"]["Name", "Value"]

    if attribute != ""
        return r[attribtue]
    end
    
    return r
end


#=
proc aws_sdb_select {aws next_token_var query} {
    # Select "query" items.

    set result {}

    set args [dict create SelectExpression $query]
    if {$next_token_var != {}} {
        upvar $next_token_var next_token
        if {$next_token != {}} {
            dset args NextToken $next_token
        }
    }
    set response [aws_sdb $aws Select {*}$args]

    while {1} {
        set response [get $response SelectResult]

        foreach {tag item} $response {
            if {$tag eq "Item"} {
                set attributes {}
                foreach {n v} $item {
                    switch $n {
                        Name      {set item_name $v}
                        Attribute {dict with v {
                                          dict lappend attributes $Name $Value}}
                    }
                }
                dset result $item_name $attributes
            }
        }

        if {![exists $response NextToken]} {
            set next_token {}
            break
        }

        set next_token [get $response NextToken]
        if {$next_token_var != {}} {
            break
        }
        set response [aws_sdb $aws Select SelectExpression $query \
                                          NextToken $next_token]
    }
    return $result
}

=#


#==============================================================================#
# End of file.
#==============================================================================#
