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

def hexlit(thing)
    case thing
    when Integer
        return "0x" + thing.to_s(16).upcase
    else
        return thing.to_s
    end
end

$global_name_map = {}

class HeaderFile
    attr_reader :file, :name, :declared_names, :required_names, :included
    def initialize(file, filter_key:nil)
        @file = file
        @name = File.basename(@file, ".yaml")

        @data = YAML::load(File.read(@file))
        @out = ""

        @data.reject! do |item|
            onlyfor = item["only-for"]
            notfor = item["not-for"]

            onlyfor = [onlyfor] if onlyfor and not onlyfor.is_a? Array
            notfor = [notfor] if notfor and not notfor.is_a? Array
            
            next true if onlyfor and not onlyfor.index(filter_key)
            next true if notfor and notfor.index(filter_key)
            next false
        end

        @data.each do |item|
            item.reject! { |k| k == "only-for" or k == "not-for" }
        end

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

    def starline
        @out << "/#{'*'*77}/\n"
    end

    def box(title, comment=nil)
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

    def decl(type, thing)
        type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
        return "#{$1}#{$2} #{$3}#{thing}#{$5}"
    end

    def collect_dep(str)
        tmp = str.to_s.dup
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
            collect_dep(member["common"]) if member["common"]
        end
    end

    def collect_dependencies
        @declared_names = Set.new
        @required_names = Set.new
        @data.each do |item|
            key, value = first_elem(item)
            @declared_names << value["name"] if value["name"]
            $global_name_map[value["name"]] = item if value["name"]
            case key
            when "enum"
                value["values"].each do |val|
                    @declared_names << val["name"]
                    collect_dep(val["value"]) if val["value"]
                end
            when "typedef"
                collect_dep(value["type"])
            when "struct", "union"
                collect_members_dependencies value["members"] if value["members"]
            when "function", "funptr"
                collect_dep(value["return"]) if value["return"]
                (value ["args"] or []).each do |arg|
                    collect_dep(arg["type"])
                end
                @declared_names.merge value["variants"] if value["variants"]
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

    def declare_function(fun, variant_index:nil)
        complex = false

        name = fun["name"]
        args = (fun["args"] or [])

        trapbits = 0

        if variant_index then
            name = fun["variants"][variant_index]
            nbits = Math.log2(fun["variants"].length).ceil

            (0..nbits-1).each do |bitidx|
                bitarg = args[-bitidx-1]
                if (variant_index & (1 << bitidx)) != 0 then
                    bitarg["register"] =~ /TrapBit<(.*)>/
                    bitval =
                        case $1 
                        when "SYSBIT" then 0x0400
                        when "CLRBIT" then 0x0200
                        else Integer($1)
                        end
                    trapbits |= bitval
                end
            end

            args = args[0..-nbits-1]
        end

        if fun["m68k-inline"] then
            m68kinlines = fun["m68k-inline"]
        else
            m68kinlines = []

            dispatcher = (fun["dispatcher"] and $global_name_map[fun["dispatcher"]]["dispatcher"])
            if dispatcher then
                sel = Integer(fun["selector"])
                case dispatcher["selector-location"]
                when "D0W", "D0<0xFF>", "D0<0xF>"
                    if sel >= -128 and sel <= 127 then
                        m68kinlines << (0x7000 | (sel & 0xFF))
                    else
                        m68kinlines << 0x303C << sel
                    end
                when "D0L", "D0<0xFFFFFF>"
                    if sel >= -128 and sel <= 127 then
                        m68kinlines << (0x7000 | (sel & 0xFF))
                    else
                        m68kinlines << 0x203C << (sel >> 16) << (sel & 0xFFFF)
                    end
                when "StackW"
                    m68kinlines << 0x3F3C << sel
                when "StackL"
                    m68kinlines << 0x2F3C << (sel >> 16) << (sel & 0xFFFF)
                when "TrapBits"
                else
                    complex = true
                end
                m68kinlines << ((fun["trap"] || dispatcher["trap"]) | trapbits)
            else
                m68kinlines << (fun["trap"] | trapbits) if fun["trap"]
            end
        end
        
        m68kinlines = m68kinlines.map {|x| hexlit(x)}
        

        if fun["args"] or fun["returnreg"] then
            regs = []
            regs << fun["returnreg"] if fun["returnreg"]
            
            args.each do |arg|
                regs << arg["register"] if arg["register"]
            end

            simpleregs = regs.map { |txt| if txt =~ /^[AD][0-7]$/ then "__"+txt else nil end }.compact
            complex = true if simpleregs.length < regs.length
            

            if simpleregs.length > 0 and not complex then
                @out << "#pragma parameter "
                @out << simpleregs.shift if fun["returnreg"]
                @out << " " << name
                @out << "(" << simpleregs.join(", ") << ")" if simpleregs.length > 0
                @out << "\n"
            end
        end

        @out << "pascal "
        @out << (fun["return"] or "void") << " "
        @out << name << "("
        
        first = true
        args.each do |arg|
            @out << ", " unless first
            first = false

            if arg["name"] then
                @out << decl(arg["type"], arg["name"])
            else
                @out << arg["type"]
            end
        end
        @out << ")"

        @out << " = { " << m68kinlines.join(", ") << " }" if m68kinlines.length > 0 and not complex

        @out << ";\n"

        @out << "enum { _#{name} = #{hexlit(fun["trap"] | trapbits)} };\n" if fun["trap"] and not fun["selector"]
    end

    def generate_header(add_includes:true)
        @out = ""
        if add_includes then
            @out << "#pragma once\n"
            @out << "#include <stdint.h>\n"
            @included.each do |file|
                @out << "#include \"#{file}.h\"\n"
            end
            @out << "\n\n"
        end

        @data.each do |item|
            key, value = first_elem(item)
        
            box(value["name"], value["comment"]) unless key == "executor_only"
        
            case key
            when "enum"
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

            when "struct", "union"
                @out << "typedef #{key} #{value["name"]} #{value["name"]};"
                
                if value["members"] then
                    @out << "#{key} #{value["name"]} {"
                    declare_members(value["members"])
                    @out << "};"
                end
                

            when "typedef"
                @out << "typedef "
                @out << decl(value["type"], value["name"])
                @out << ";"
        
            when "function"
                if value["variants"] then
                    value["variants"].each_index { |i| declare_function(value, variant_index:i) }
                else
                    declare_function(value)
                end

            when "lowmem"
                if value["type"] =~ /\[[^\[\]]*\]$/ then
                    @out << "#define LMGet#{value["name"]}() ((#{value["type"]}*)#{hexlit(value["address"])})\n"
                else
                    @out << "#define LMGet#{value["name"]}() (*(#{value["type"]}*)#{hexlit(value["address"])})\n"
                    @out << "#define LMSet#{value["name"]}(val) ((*(#{value["type"]}*)#{hexlit(value["address"])}) = (val))\n"
                end

            when "funptr"
                @out << "typedef pascal "

                name = value["name"]
                if name=~/^([A-Za-z_][A-Za-z0-9]*)(ProcPtr|UPP)$/ then
                    print "ProcPtr: #{name} -> #{$1}\n"
                    name = $1 
                else
                    print "WARNING: strange function pointer #{name}\n"
                end
                              

                @out << (value["return"] or "void") << " "
                @out << "(*" << name << "ProcPtr" << ")("

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
                @out << ");\n"

                @out << "typedef #{name}ProcPtr #{name}UPP;\n"
                @out << "#define New#{name}Proc(proc) (proc)\n"
                @out << "#define New#{name}UPP(proc) (proc)\n"
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
    
    header = HeaderFile.new(file, filter_key: "CIncludes")
    headers[header.name] = header

    header.declared_names.each { |n| declared_names[n] = header.name }
end

print "Linking things up...\n"
headers.each do |name, header|
    header.collect_includes(declared_names)
end

def check_cycle(visited, headers, name, stack="")
    visited << name

    headers[name].included.each do |inc|
        if visited.member?(inc) then
            print "INCLUDE CYCLE #{stack} -> #{name} --> #{inc}\n"
        end
        check_cycle(visited, headers, inc, stack + " -> " + name)
    end

    visited.delete(name)
end
headers.each do |name, header|
    #print "Checking #{name}...\n"

    check_cycle(Set.new, headers, name)
end

def write_ordered(file, header, headers, visited)
    return if visited.member?(header.name)
    visited << header.name
    print "Generating #{header.name}\n"
    
    header.included.each do |incname|
        write_ordered(file, headers[incname], headers, visited)
    end

    file << header.generate_header(add_includes: false)
end

if false then
    headers.each do |name, header|
        print "Processing #{name}...\n"

        out = header.generate_header

        IO.popen("clang-format > out/#{header.name}.h", "w") do |f|
            f << out
        end

    end

    File.open("out/Multiverse.h", "w") do |file|
        headers.each { |name,_| file.write "#include \"#{name}.h\"\n" }
    end
else
    IO.popen("clang-format > out/Multiverse.h", "w") do |f|
        f << <<~PREAMBLE
            #pragma once
            #include <stdint.h>
            #include <stdbool.h>
            #include <stddef.h>
            
            typedef void (*ProcPtr)();
            #define nil NULL

            #define STACK_ROUTINE_PARAMETER(n, sz) ((sz) << (kStackParameterPhase + ((n)-1) * kStackParameterWidth))
        PREAMBLE

        visited = Set.new
        headers.each do |name, header|
            write_ordered(f, header, headers, visited)
        end

        f << "\n\nextern QDGlobals qd;\n"
    end

    ["Carbon", "Devices", "Dialogs", "Errors", "Events", "Files", "FixMath",
     "Fonts", "Icons", "LowMem", "MacMemory", "MacTypes", "Memory", "Menus",
     "MixedMode", "NumberFormatting", "OSUtils", "Processes", "Quickdraw",
     "Resources", "SegLoad", "Sound", "TextEdit", "TextUtils", "ToolUtils",
     "Traps", "Windows", "ConditionalMacros", "Gestalt"].each do |name|
        File.open("out/#{name}.h", "w") do |f|
            f << "#pragma once\n"
            f << "#include \"Multiverse.h\"\n"
        end
    end
end
