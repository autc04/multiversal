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

    def make_title(header)
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

    def formatted_file(name, &block)
        IO.popen("clang-format | grep -v \"// clang-format o\" > #{name}", "w", &block)
    end
end
