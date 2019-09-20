require 'yaml'
require 'set'
require 'fileutils'

require './generator'
require './cincludes'
require './executor'

BUILTIN_NAMES=Set.new [
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "char",
    "ProcPtr",
    "void",
    "const",
    "bool",
    "sizeof",
    "double"
]

def hexlit(thing, sz=16)
    case thing
    when Integer
        digits = thing.to_s(16).upcase
        return "0x" + "0" * [sz/4 - digits.length, 0].max + digits
    else
        return thing.to_s
    end
end

def first_elem(item)
    item.each { |key, value| return key, value }
end

$global_name_map = {}

class HeaderFile
    attr_reader :file, :name, :declared_names, :required_names, :included, :included_why, :data
    def initialize(file, filter_key:nil)
        @file = file
        @name = File.basename(@file, ".yaml")

        @data = YAML::load(File.read(@file))

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
        @included_why = nil
    end

private

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
        @included_why = {}
        @required_names.each do |n|
            where = all_declared_names[n]
            if where then
                @included << where
                @included_why[where] = Set.new unless @included_why[where]
                @included_why[where] << n
            else
                print "??????????????? Where is #{n}\n"
            end
        end
    end

end

class Defs
    attr_reader :headers, :declared_names, :topsort
    def initialize(filter_key:nil)
        @headers = {}
        @declared_names = {}        

        Dir.glob('defs/*.yaml') do |file|
            print "Reading #{file}...\n"
            
            header = HeaderFile.new(file, filter_key: filter_key)
            @headers[header.name] = header
        
            header.declared_names.each { |n| @declared_names[n] = header.name }
        end
        
        print "Linking things up...\n"
        headers.each do |name, header|
            header.collect_includes(declared_names)
        end
        
        @topsort = []
        done = Set.new
        headers.each do |name, header|
            do_topsort(name, done)
        end
    end

private

    def do_topsort(name, done, active=Set.new, stack=[])
        print "INCLUDE CYCLE #{stack.join('=>')} => #{name}\n" if active.include?(name)
        return if done.include?(name)
        active << name
        done << name
        stack << name

        @headers[name].included.each do |incname|
            do_topsort(incname, done, active, stack)
        end
        @topsort << name
        active.delete?(name)
        stack.pop
    end
end



what = ARGV[0] or "--cincludes"
case what
when "--cincludes"
    defs = Defs.new(filter_key: "CIncludes")
    CIncludesGenerator.new.generate(defs)
when "--executor"
    defs = Defs.new(filter_key: "executor")
    ExecutorGenerator.new.generate(defs)
else
    print("what?? '#{what}'\n")
end