require './generator'

class ExecutorGenerator < Generator
    def self.filter_key
        "executor"
    end

    def initialize
        super
        @need_guest = false
        @noguest_types = Set.new(["void"])
        @expand_common = false
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
        size_of_type(type) != 1 && ! @noguest_types.include?(type)
    end

    def guestify_type(type, guest)
        type.strip!
        return type, "", "" if not type_needs_guest?(type)
        if type =~ /^(.*)(\[[^\[\]]*\])$/ then
            post = $2
            type1, _, _ = guestify_type($1, true)
            
            #if guest then
            #    return "GUEST<#{type1}#{post}>", "", ""
            #else
                return type1, "", post
            #end
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
        if value["size"] then
            @out << "static_assert(sizeof(#{value["name"]}) == #{value["size"]});"
        end
    end
    def declare_dispatcher(value, extern:false)
        @available_dispatchers << value["name"]
        @out << "EXTERN_" if extern
        @out << "DISPATCHER_TRAP(#{value["name"]}, "
        @out << "#{hexlit(value["trap"])}, #{value["selector-location"]});\n"
    end
    def declare_lowmem(value)
        @out << "const LowMemGlobal<#{decl(value["type"])}> #{value["name"]}"
        @out << "{ #{hexlit(value["address"],12)} };"
    end

    def handle_regcall_conv(fun)
        args = (fun["args"] or [])
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
        @out << ", " << fun["executor_extras"] if fun["executor_extras"]
    end

    def declare_function(fun)
        if fun["dispatcher"] && ! @available_dispatchers.include?(fun["dispatcher"]) then
            disp = $global_name_map[fun["dispatcher"]]
            if disp and disp["dispatcher"] then
                declare_dispatcher(disp["dispatcher"], extern:true)
            end
        end

        name = fun["name"]
        dispatcher = (fun["dispatcher"] && $global_name_map[fun["dispatcher"]]["dispatcher"])
        trap = (fun["trap"] or (dispatcher and dispatcher["trap"]))

        cname = name
        if fun["executor"] then
            if fun["executor"].is_a?(String) then
                if fun["executor"] =~ /_$/ then
                    cname = fun["executor"] + name
                else
                    cname = fun["executor"]
                end
            end    
        end
        two = name == cname ? "2" : ""

        @out << (fun["return"] or "void") << " " << cname

        args = (fun["args"] or [])

        @out << "(" << (args.map {|arg| decl(arg["type"], arg["name"])}).join(", ") << ");"

        if fun["file_trap"] == "hfs" then
            trap_sel_disp = hexlit(Integer(trap) & 0xA0FF)
        else
            trap_sel_disp = hexlit(trap)
        end
        if fun["selector"] then
            sub = "SUB"
            trap_sel_disp += ", #{hexlit(fun["selector"])}, #{hexlit(fun["dispatcher"])}"
        else
            sub = ""
        end

        if not fun["executor"] then
        elsif fun["file_trap"] == "mfs" then
        elsif fun["file_trap"] == "hfs" then
            @out << "HFS_#{sub}TRAP(#{name.gsub(/^PBH/,"PB")}, #{name}, "
            @out << "#{fun["args"][0]["type"]}, #{trap_sel_disp});"
        elsif fun["file_trap"] then
            @out << "FILE_#{sub}TRAP(#{name}, #{fun["args"][0]["type"]}, #{trap_sel_disp});"
        elsif trap && (fun["executor_extras"] || fun["returnreg"] || args.any? {|arg| arg["register"]}) then
            if fun["variants"] then
                variants = fun["variants"]
                nflagstr = variants.size >= 3 ? "2" : ""
                @out << "REGISTER_#{nflagstr}FLAG_TRAP(#{cname}, #{variants.join(", ")}, "
                @out << "#{hexlit(trap)}, "
                @out << (fun["return"] or "void")
                args1 = variants.size >= 3 ? fun["args"][0..-3] : fun["args"][0..-2]
                @out << "(" << (args1.map {|arg| decl(arg["type"])}).join(", ") << ")"
                @out << ", "
            else
                @out << "REGISTER_#{sub}TRAP#{two}(#{name}, #{trap_sel_disp}, "
            end
            handle_regcall_conv(fun)
            @out << ");\n"
        elsif fun["selector"] then
            @out << "PASCAL_SUBTRAP(#{name}, #{hexlit(trap)}, "
            @out << "#{hexlit(fun["selector"])}, #{hexlit(fun["dispatcher"])});\n"
        elsif trap then
            if name == cname then
                if args.size == 0 && !fun["return"] then
                    @out << "REGISTER_TRAP2(#{name}, #{hexlit(trap)}, void());\n"
                else
                end
            else
                @out << "PASCAL_TRAP(#{name}, #{hexlit(trap)});\n"
            end
        else
            @out << "NOTRAP_FUNCTION#{two}(#{name});\n"
        end
    end

    def declare_funptr(value)
        name = value["name"]
        args = (value["args"] or [])

        @out << "using #{name} = UPP<"
        @out << (value["return"] or "void") << "("
        args = (value["args"] or [])
        @out << args.map {|arg|decl(arg["type"], arg["name"])}.join(", ")
        @out << ")"
        if value["returnreg"] || value["executor_extras"] || args.any? {|arg| arg["register"]} then
            @out << ", Register<"
            handle_regcall_conv(value)
            @out << ">"
        end
        @out << ">;\n"
    end

    def declare_verbatim(value)
        @out << "BEGIN_EXECUTOR_ONLY\n"
        @out << value.strip << "\n"
        @out << "END_EXECUTOR_ONLY\n"
    end

    def remap_name(name)
        name == "MacTypes" ? "ExMacTypes" : name
    end
     
    def generate_preamble(header)
        super
        @out << "#pragma once\n"
        if header.name == "MacTypes" then
            @out << "#include \"base/mactype.h\"\n"
            @out << "#include <cassert>\n"
            @out << "#include <base/lowglobals.h>\n"
        end

        header.included.each do |file|
            @out << "#include \"#{remap_name(file)}.h\"\n"
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

    def generate_header(header)
        @current_header = header
        @available_dispatchers = Set.new
        super
    end

    def generate(defs)
        print "Writing Headers...\n"
        FileUtils.mkdir_p "#{$options.output_dir}/"
        defs.topsort.each do |name|
            formatted_file "#{$options.output_dir}/#{remap_name(name)}.h" do |f|
                f << generate_header(defs.headers[name])
            end
        end
        print "Done.\n"
    end
end