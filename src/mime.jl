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
