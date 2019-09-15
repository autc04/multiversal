class Generator
    def starredtext(str, align, lchar:'*', rchar:'*')
        maxlinelen = str.lines.map{|s| s.rstrip.length}.max
        
        str.each_line do |s|
            s.rstrip!
            c = (75 - s.length)
            b = case align
                when "center" then c/2
                when "left" then c - 1
                when "right" then 1
            end
            a = c - b
            a = 0 if a < 0
            b = 0 if b < 0
            @out << " #{lchar}#{' '*a}#{s}#{' '*b}#{rchar}\n"
        end

    end

    def starline
        @out << "/#{'*'*77}/\n"
    end

    def box(title, comment=nil, order:1)
        if title or comment then
            @out << "/#{'*'*77}\n"
            #print " *#{' '*75}*\n"
            starredtext(title, 'center') if title
            @out << " *#{' '*75}*\n" if title and comment
            starredtext(comment, 'left') if comment

            @out << " #{'*'*77}/\n"
        else
            starline
        end
    end


    def document_dependencies(header)
        out = ""
        if header.included.size > 0 then
            out << "Needs:\n"
            
            colwidth = header.included.map(&:size).max + 4 + 2 + 4
            maxlinelen = 70

            header.included.each do |inc|
                line = " " * 4 + inc + ".h"
                line << " " * (colwidth - line.length)
                indent = line.length
                whys = header.included_why[inc].to_a
                whys.each_index do |idx|
                    why = whys[idx]
                    last = (idx == whys.size - 1)
                    if line.length + why.size + (last ? 0 : 1) > maxlinelen
                        out << line << "\n"
                        line = " " * indent
                    end
                    line << why
                    line << ", " unless last
                end
                out << line << "\n"
            end
        end
        return out
    end

    def declare_members(members)
        members.each do |member|
            sub = (member["struct"] or member["union"])
            if sub then
                @out << (if member["struct"] then "struct" else "union" end) << "{"
                declare_members sub
                @out << "} " << member["name"] << ";"
            elsif member["common"]
                declare_members($global_name_map[member["common"]]["common"]["members"])
            else
                @out << decl(member["type"], member["name"]) << ";"
            end
        end
    end

    def declare_enum(value)
        @out << "typedef " if value["name"]
        @out << "enum {"
        value["values"].each do |val|
            @out << val["name"]
            if val["value"] then
                @out << "= " << val["value"].to_s << ","
            else
                @out << ","
            end
        end
        @out << "}"
        @out << value["name"] if value["name"]
        @out << ";"
    end

    def declare_typedef(value)
        @out << "typedef "
        @out << decl(value["type"], value["name"])
        @out << ";"

        sz = size_of_type(value["type"])
        $type_size_map[value["name"]] = sz if sz
    end

    def generate_preamble(header)
        title = "\n" + header.name + ".h\n" + "="*(header.name.length+2) + "\n"
        titlecomment = nil
        if header.included.size > 0 then
            titlecomment = document_dependencies(header)
            titlecomment << "\n\n"
        else
            title << "\n"
        end
        box(title, titlecomment)
        @out << "\n\n"
    end
    def generate_postamble(header)
        box(value["name"], value["comment"])
    end
    def generate_comment(key, value)
        box(value["name"], value["comment"]) unless key == "executor_only"
    end


    def generate_header(header)
        @out = ""
        @impl_out = ""

        generate_preamble(header)

        header.data.each do |item|
            key, value = first_elem(item)
            generate_comment(key, value)
        
            case key
            when "enum"
                declare_enum(value)

            when "struct", "union"
                declare_struct_union(key, value)

            when "dispatcher"
                declare_dispatcher(value)

            when "typedef"
                declare_typedef(value)

            when "function"
                declare_function(value)

            when "lowmem"
                declare_lowmem(value)

            when "funptr"
                declare_funptr(value)
            end
        
            @out << "\n\n"
        end
        
        return @out
    end

    def formatted_file(name, &block)
        IO.popen("clang-format | grep -v \"// clang-format o\" > #{name}", "w", &block)
    end
end