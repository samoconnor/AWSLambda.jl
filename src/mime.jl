#==============================================================================#
# mime.jl
#
# Simple MIME Multipart encoder.
#
# e.g.
#
# mime_multipart([
#     ("foo.txt", "text/plain", "foo"),
#     ("bar.txt", "text/plain", "bar")
# ])
# 
# returns...
#
#   "MIME-Version: 1.0
#   Content-Type: multipart/mixed; boundary=\"=PRZLn8Nm1I82df0Dtj4ZvJi=\"
#
#   --=PRZLn8Nm1I82df0Dtj4ZvJi=
#   Content-Disposition: attachment; filename=foo.txt
#   Content-Type: text/plain
#   Content-Transfer-Encoding: binary 
#
#   foo
#   --=PRZLn8Nm1I82df0Dtj4ZvJi=
#   Content-Disposition: attachment; filename=bar.txt
#   Content-Type: text/plain
#   Content-Transfer-Encoding: binary 
#
#   bar
#   --=PRZLn8Nm1I82df0Dtj4ZvJi=
#
#
# Copyright Sam O'Connor 2015 - All rights reserved
#==============================================================================#


function mime_multipart(parts::Array)

    boundary = "=PRZLn8Nm1I82df0Dtj4ZvJi="

    mime = 
    """
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="$boundary"

    --$boundary
    """

    for (filename, content_type, content) in parts

        mime *=
        """
        Content-Disposition: attachment; filename=$filename
        Content-Type: $content_type
        Content-Transfer-Encoding: binary 

        $content
        --$boundary
        """
    end

    return mime
end



#==============================================================================#
# End of file
#==============================================================================#
