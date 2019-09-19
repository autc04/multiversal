require './generator'

class ExecutorGenerator < Generator
    def initialize
        super
        @need_guest = false
        @noguest_types = Set.new(["void"])
    end

    def need_guest
        if @need_guest then
            return yield
        else
            @need_guest = true
            result = yield
            @need_guest = false
            return result
        end
    end

    def type_needs_guest?(type)
        size_of_type(type) != 1 and not @noguest_types.include?(type)
    end

    def guestify_type(type, guest)
        type.strip!
        return type, "", "" if not type_needs_guest?(type)
        if type =~ /^(.*)(\[[^\[\]]*\])$/ then
            post = $2
            type1, _, _ = guestify_type($1, true)
            
            if guest then
                return "GUEST<#{type1}#{post}>", "", ""
            else
                return type1, "", post
            end
        elsif type =~ /^(.*)\*$/ then
            type1, _, _ = guestify_type($1, true)

            if guest then
                return "GUEST<#{type1}*>", "", ""
            else
                return type1, "*", ""
            end
        elsif guest then
            if type =~ /^const[ \t]+(.*)$/ and not type_needs_guest?($1) then
                return type
            else
                return "GUEST<#{type}>"
            end
        else
            return type, "", ""
        end
    end

    def decl(type, thing=nil)
        t1, pre, post = guestify_type(type, @need_guest)
        
        return "#{t1} #{pre}#{thing}#{post}"
    end

    def convert_expression(expr)
        return expr.gsub(/\'([^\']+)\'/) {|x| "\"#{$1}\"_4"}
    end

    def declare_struct_union(what, value)
        @noguest_types << value["name"]
        
        @out << "#{what} #{value["name"]}"
        if value["members"] then
            @out << "{"
            @out << "GUEST_STRUCT;"
            need_guest { declare_members(value["members"]) }
            @out << "}"
        end
        @out << ";"
    end
    def declare_dispatcher(value)
        @out << "DISPATCHER_TRAP(#{value["name"]}, "
        @out << "#{hexlit(value["trap"])}, #{value["selector-location"]});\n"
    end
    def declare_lowmem(value)
        @out << "const LowMemGlobal<#{decl(value["type"])}> #{value["name"]}"
        @out << "{ #{hexlit(value["address"],12)} };"
    end

    def declare_function(fun)
        renamed = true

        name = fun["name"]
        dispatcher = (fun["dispatcher"] and $global_name_map[fun["dispatcher"]]["dispatcher"])
        trap = (fun["trap"] or (dispatcher and dispatcher["trap"]))

        cname = renamed ? "C_"+name : name
        @out << (fun["return"] or "void") << " " << cname

        args = (fun["args"] or [])

        @out << "(" << (args.map {|arg| decl(arg["type"], arg["name"])}).join(", ") << ");"

        if trap and (fun["returnreg"] or args.any? {|arg| arg["register"]}) then
            if fun["selector"] then
                @out << "REGISTER_SUBTRAP(#{name}, #{hexlit(trap)}, "
                @out << "#{hexlit(fun["selector"])}, #{hexlit(fun["dispatcher"])}, "
            else
                @out << "REGISTER_TRAP(#{name}, #{hexlit(trap)}, "
            end
            @out << (fun["returnreg"] or "void")
            argregs = args.map do |arg|
                basetype = $1 if arg["type"] =~ /^(.*)\* *$/
                if arg["register"] =~ /^Out<(.*)>$/ then
                    "Out<#{basetype}, #{$1}>"
                elsif arg["register"] =~ /^InOut<(.*)>$/ then
                    "InOut<#{basetype}, #{$1}>"
                else
                    arg["register"]
                end
            end
            @out << "(" << argregs.join(", ") << ")"

            @out << ");\n"
        elsif fun["selector"] then
            @out << "PASCAL_SUBTRAP(#{name}, #{hexlit(trap)}, "
            @out << "#{hexlit(fun["selector"])}, #{hexlit(fun["dispatcher"])});\n"
        elsif trap then
            @out << "PASCAL_TRAP(#{name}, #{hexlit(trap)});\n"
        else
            @out << "NOTRAP_FUNCTION(#{name});\n"
        end
    end

    def declare_funptr(value)
        name = value["name"]
        args = (value["args"] or [])

        @out << "using #{name} = UPP<"
        @out << (value["return"] or "void") << "("
        args = (value["args"] or [])
        @out << args.map {|arg|decl(arg["type"], arg["name"])}.join(", ")
        @out << ")>;\n"

        if args.any? {|arg| arg["register"]} then
            procinfo = 42;
            print "WARNING UNSUPPORTED register funptr: #{name}\n"
        end
    end

    def generate_preamble(header)
        super
        @out << "#pragma once\n"

        header.included.each do |file|
            @out << "#include \"#{file}.h\"\n"
        end
        @out << "\n"

        @out << "#define MODULE_NAME #{header.name}\n"
        @out << "#include <base/api-module.h>\n"

        @out << "\n\n"

        @out << "namespace Executor {\n\n"
    end

    def generate_postamble(header)
        @out << "} /* namespace Executor */"
    end

    def generate(defs)
        FileUtils.mkdir_p "out/executor"
        defs.topsort.each do |name|
            formatted_file "out/executor/#{name}.h" do |f|
                f << generate_header(defs.headers[name])
            end
        end
    end
end