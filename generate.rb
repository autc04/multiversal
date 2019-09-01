require 'yaml'
require 'set'


BUILTIN_NAMES=Set.new [
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "char",
    "ProcPtr",
    "void",
    "const",
    "bool",
    "sizeof"
]

class HeaderFile
    attr_reader :file, :name, :declared_names, :required_names, :included
    def initialize(file)
        @file = file
        @name = File.basename(@file, ".yaml")

        @data = YAML::load(File.read(@file))
        @out = ""

        collect_dependencies

        @included = nil
    end

private

    def first_elem(item)
        item.each { |key, value| return key, value }
    end

    def starredtext(str, align)
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

    def collect_dep(str)
        tmp = str.to_s
        tmp.gsub!(/'[^']+'/,"")
        tmp.scan(/[a-zA-Z_][a-zA-Z0-9_]*/).each do |x|
            @required_names << x unless BUILTIN_NAMES.member?(x)
        end
    end

    def collect_members_dependencies(members)
        members.each do |member|
            collect_dep(member["type"]) if member["type"]
            collect_members_dependencies(member["struct"]) if member["struct"]
            collect_members_dependencies(member["union"]) if member["union"]
        end
    end

    def collect_dependencies
        @declared_names = Set.new
        @required_names = Set.new
        @data.each do |item|
            key, value = first_elem(item)
            @declared_names << value["name"] if value["name"]

            case key
            when "enum"
                value["values"].each do |val|
                    @declared_names << val["name"]
                    collect_dep(val["value"]) if val["value"]
                end
            when "struct", "union"
                collect_members_dependencies value["members"] if value["members"]
            when "function", "funptr"
                collect_dep(value["return"]) if value["return"]
                (value ["args"] or []).each do |arg|
                    collect_dep(arg["type"])
                end
            end
        end
        @required_names = @required_names - @declared_names
    end

public
    def collect_includes(all_declared_names)
        @included = Set.new
        @required_names.each { |n|
            included << all_declared_names[n] if all_declared_names[n]
            print "??????????????? Where is #{n}\n" unless all_declared_names[n]
        }
    end

    def generate_header
        @out = ""
        @out << "#include <stdint.h>\n"
        @included.each do |file|
            @out << "#include \"#{file}.h\"\n"
        end
        @out << "\n\n"

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

            when "struct", "union"
                @out << "typedef #{key} #{value["name"] or ""}"
                if value["members"] then
                    @out << " {"
                    value["members"].each do |member|
                        @out << decl(member["type"], member["name"]) << ";"
                    end
                    @out << "}"
                end
                @out << " #{value["name"]};"
        

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

headers = {}
declared_names = {}

Dir.glob('defs/*.yaml') do |file|
    print "Reading #{file}...\n"
    
    header = HeaderFile.new(file)
    headers[header.name] = header

    header.declared_names.each { |n| declared_names[n] = header.name }
end

print "Linking things up...\n"
headers.each do |name, header|
    header.collect_includes(declared_names)
end

def visit(visited, headers, name, stack="")
    visited << name

    headers[name].included.each do |inc|
        if visited.member?(inc) then
            print "INCLUDE CYCLE #{stack} -> #{name} --> #{inc}\n"
        end
        visit(visited, headers, inc, stack + " -> " + name)
    end

    visited.delete(name)
end
headers.each do |name, header|
    #print "Checking #{name}...\n"

    visit(Set.new, headers, name)
end

headers.each do |name, header|
    print "Processing #{name}...\n"
    

    out = header.generate_header

    IO.popen("clang-format > out/#{header.name}.h", "w") do |f|
        f << out
    end

end
