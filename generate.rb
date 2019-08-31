require 'yaml'

class HeaderFile
    attr_reader :file, :name
    def initialize(file)
        @file = file
        @name = File.basename(@file, ".yaml")

        @data = YAML::load(File.read(@file))
        @out = ""
    end

private

    def first_elem(item)
        item.each { |key, value| return key, value }
    end

    def starredtext(str, align)
        maxlinelen = str.lines.map{|s| s.length}.max
        
        str.each_line do |s|
            c = (75 - s.length)
            b = case align
                when "center" then c/2
                when "left" then c - 1
                when "right" then 1
            end
            a = c - b
            a = 0 if a < 0
            b = 0 if b < 0
            @out << " *#{' '*a}#{s}#{' '*b}*\n"
        end

    end

    def box(title, comment=nil)
        return unless title or comment
        @out << "/#{'*'*77}\n"
        #print " *#{' '*75}*\n"
        starredtext(title, 'center') if title
        @out << " *#{' '*75}*\n" if title and comment
        starredtext(comment, 'left') if comment

        @out << " #{'*'*77}/\n"
        
    end

    def decl(type, thing)
        type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
        return "#{$1}#{$2} #{$3}#{thing}#{$5}"
    end

public

    def generate_header()
        @out
        @data.each do |item|
            key, value = first_elem(item)
        
            box(value["name"], value["comment"])
        
            case key
            when "enum"
                @out << "typedef " if value["name"]
                @out << "enum {"
                value["values"].each do |val|
                    @out << val["name"]
                    if val["value"] then
                        @out << "=" << val["value"].to_s << ","
                    else
                        @out << ","
                    end
                end
                @out << "}"
                @out << value["name"] if value["name"]
                @out << ";"

            when "struct"
                @out << "typedef struct #{value["name"] or ""} {"
                value["members"].each do |member|
                    @out << decl(member["type"], member["name"]) << ";"
                end
                @out << "} #{value["name"]};"
        
            when "typedef"
                @out << "typedef "
                @out << decl(value["type"], value["name"])
                @out << ";"
        
            when "function"
                if value["trap"] and not value["selector"] and not value["registers"] then
                    @out << "pascal "
                end
                @out << (value["return"] or "void") << " "
                @out << value["name"] << "("
                
                first = true
                value["args"] and value["args"].each do |arg|
                    @out << "," unless first
                    first = false
        
                    if arg["name"] then
                        @out << decl(arg["type"], arg["name"])
                    else
                        @out << arg["type"]
                    end
                end
                @out << ");"
            end
        
            @out << "\n\n"
        end
        
        return @out
    end

end
        
Dir.glob('defs/*.yaml') do |file|
    print "Reading #{file}...\n"
    
    header = HeaderFile.new(file)
    out = header.generate_header

    IO.popen("clang-format > out/#{header.name}.h", "w") do |f|
        f << out
    end
end
