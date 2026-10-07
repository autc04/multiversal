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
            if type =~ /^const[ \t]+(.*)$/ then
                if type_needs_guest?($1) then
                    return "const GUEST<#{$1}>"
                else
                    return type
                end
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
        # Incomplete types (forward declarations only) have nothing to describe.
        if value["members"] then
            @out << "void describeStruct(const #{value["name"]}&, std::ostream&);"
        end
    end

    # Emit logging::logField calls describing each leaf member, expanding
    # `common` macros and recursing into anonymous nested struct/union members.
    def describe_members(out, members, access, label)
        members.each do |member|
            if member["common"] then
                describe_members(out, $global_name_map[member["common"]]["common"]["members"],
                                 access, label)
            elsif member["struct"] or member["union"] then
                sub = member["struct"] || member["union"]
                describe_members(out, sub, "#{access}#{member["name"]}.",
                                 "#{label}#{member["name"]}.")
            else
                out << "    logging::logField(os, \"#{label}#{member["name"]}\", "
                out << "#{access}#{member["name"]});\n"
            end
        end
    end

    def describe_struct(out, value)
        out << "void describeStruct(const #{value["name"]}& x, std::ostream& os)\n"
        out << "{\n"
        out << "    os << \"#{value["name"]}{\";\n"
        describe_members(out, value["members"] || [], "x.", "")
        out << "    os << \"}\";\n"
        out << "}\n"
    end

    # Net effect of the preprocessor conditionals opened/closed by a verbatim
    # block, so structs declared inside an `#if` (e.g. mc68000-only) are skipped.
    def preprocessor_depth_delta(text)
        delta = 0
        text.each_line do |line|
            s = line.strip
            if s =~ /^#\s*(if|ifdef|ifndef)\b/
                delta += 1
            elsif s =~ /^#\s*endif\b/
                delta -= 1
            end
        end
        delta
    end

    # Struct/union definitions to describe for a header, de-duplicated by name
    # (an opaque forward declaration can be followed by the full definition) and
    # skipping types declared inside verbatim `#if` blocks (e.g. mc68000-only).
    # Returns [ordered names, name => richest value].
    def struct_definitions(header)
        defs = {}
        order = []
        depth = 0
        header.data.each do |item|
            key, value = main_elem(item)
            if key == "verbatim"
                depth += preprocessor_depth_delta(value)
                next
            end
            next if depth > 0
            next unless key == "struct" or key == "union"
            next if item["api"] == "carbon"
            # Only complete types (with members) can be described/sized.
            next if (value["members"] || []).empty?
            name = value["name"]
            if !defs.key?(name)
                defs[name] = value
                order << name
            elsif (value["members"] || []).size > (defs[name]["members"] || []).size
                defs[name] = value
            end
        end
        [order, defs]
    end

    def generate_structdump(header, module_name, best)
        out = ""
        out << "// Generated by make-multiverse.rb - DO NOT EDIT\n"
        out << "#include <base/structdump.h>\n"
        out << "#include <base/logging.h>\n"
        out << "#include <#{module_name}.h>\n\n"

        order, defs = struct_definitions(header)
        # A type defined in more than one module is described only where it has
        # the fullest definition.
        emitted = order.select { |name| best[name][0] == module_name }

        out << "namespace Executor\n{\n"
        emitted.each do |name|
            describe_struct(out, defs[name])
            out << "\n"
        end
        out << "} // namespace Executor\n\n"

        # Registration table for the type registry (used by the cxmon `dt`
        # command).  Kept in namespace structdump so the generated names resolve
        # the types and describeStruct in the enclosing Executor namespace.
        out << "namespace Executor { namespace structdump {\n"
        out << "namespace\n{\n"
        emitted.each do |name|
            out << "void dump_#{name}(std::ostream& os, const void* p)\n"
            out << "{\n"
            out << "    describeStruct(*(const #{name}*)p, os);\n"
            out << "}\n"
        end
        out << "}\n\n"
        out << "void registerStructDumps_#{module_name}()\n"
        out << "{\n"
        unless emitted.empty?
            out << "    static const TypeDesc types[] = {\n"
            emitted.each do |name|
                out << "        { \"#{name}\", sizeof(#{name}), &dump_#{name} },\n"
            end
            out << "    };\n"
            out << "    registerTypes(types, sizeof(types) / sizeof(types[0]));\n"
        end
        out << "}\n"
        out << "}} // namespace Executor::structdump\n"
        out
    end

    # The single translation unit that references every per-module registration
    # function, so none of the generated structdump objects are stripped by the
    # linker.
    def generate_reference_all_struct_dumps(modules)
        out = "// Generated by make-multiverse.rb - DO NOT EDIT\n"
        out << "#include <base/structdump.h>\n\n"
        out << "namespace Executor { namespace structdump {\n"
        modules.each { |m| out << "void registerStructDumps_#{m}();\n" }
        out << "\nvoid registerAllStructDumps()\n{\n"
        modules.each { |m| out << "    registerStructDumps_#{m}();\n" }
        out << "}\n}}\n"
        out
    end
    def declare_dispatcher(value, extern:false)
        @available_dispatchers << value["name"]
        @out << "EXTERN_" if extern
        @out << "DISPATCHER_TRAP(#{value["name"]}, "
        @out << "#{hexlit(value["trap"])}, #{value["selector-location"]});\n"
    end
    def declare_lowmem(value)
        @out << "const LowMemGlobal<#{decl(value["type"])}> #{value["name"]}"
        @out << "{ #{hexlit(value["address"],12)} };\n"
        # @out << "LOWMEM_ACCESSOR(#{value["name"]});\n"
        if value["type"] =~ /^(.*)\[[^\[\]]*\]$/ then
        #    @out << "inline GUEST<#{$1}>* LMGet#{value["name"]}() { return LM(#{value["name"]}); }\n"
        #    @out << "NOTRAP_FUNCTION2(LMGet#{value["name"]});\n"
        else
            sz = size_of_type(value["type"])

            if !sz || sz > 4 then
                @out << "inline void LMGet#{value["name"]}(#{decl(value["type"]+"*", "val")}) { *val = LM(#{value["name"]}); }\n"
                @out << "inline void LMSet#{value["name"]}(#{decl("const " + value["type"]+"*", "val")}) { LM(#{value["name"]}) = *val; }\n"
            else
                @out << "inline #{decl(value["type"])} LMGet#{value["name"]}() { return LM(#{value["name"]}); }\n"
                @out << "inline void LMSet#{value["name"]}(#{decl(value["type"],"val")}) { LM(#{value["name"]}) = val; }\n"
            end
            @out << "NOTRAP_FUNCTION2(LMGet#{value["name"]});\n"
            @out << "NOTRAP_FUNCTION2(LMSet#{value["name"]});\n"
    end

    end

    # Structured view of a Register<...> spec, shared by the header emitter and
    # the generated entrypoints.
    def regcall_conv(fun)
        args = (fun["args"] or [])
        argconvs = args.map do |arg|
            basetype = $1 if arg["type"] =~ /^(.*)\* *$/
            if arg["register"] =~ /^Out<(.*)>$/ then
                "Out<#{basetype}, #{$1}>"
            elsif arg["register"] =~ /^InOut<(.*)>$/ then
                "InOut<#{basetype}, #{$1}>"
            else
                arg["register"]
            end
        end
        { ret: (fun["returnreg"] or "void"), args: argconvs,
          extras: fun["executor_extras"] }
    end

    def handle_regcall_conv(fun)
        conv = regcall_conv(fun)
        @out << conv[:ret]
        @out << "(" << conv[:args].join(", ") << ")"
        @out << ", " << conv[:extras] if conv[:extras]
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

        arg_decls = args.map {|arg| decl(arg["type"], arg["name"])}
        @out << "(" << arg_decls.join(", ") << ");"

        # Argument types without names, captured here so the entrypoint
        # generator sees the same GUEST<>-ness the declaration got.
        arg_types = args.map {|arg| decl(arg["type"], "").strip}
        arg_names = args.each_with_index.map {|arg, i| arg["name"] || "arg#{i}"}

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
            info = register_entry_info(fun, name, cname, trap, arg_types, arg_names, arg_decls)
            if info then
                @out << emit_wrapper(info)
                @entries << info
            else
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
            end
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
                ret = (fun["return"] or "void")
                info = pascal_entry_info(name, cname, trap, ret, arg_types, arg_names, arg_decls)
                if info then
                    @out << emit_wrapper(info)
                    @entries << info
                else
                    @out << "PASCAL_TRAP(#{name}, #{hexlit(trap)});\n"
                end
            end
        else
            @out << "NOTRAP_FUNCTION#{two}(#{name});\n"
        end
    end

    def pascal_entry_info(name, cname, trap, ret, arg_types, arg_names, arg_decls)
        return nil unless cname == "C_" + name
        # Types with commas or brackets can't be a single template argument.
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        { kind: :pascal, name: name, object: name, impl: cname, trap: trap, ret: ret,
          arg_types: arg_types, arg_names: arg_names, arg_decls: arg_decls, cc: "" }
    end

    # A Register-convention trap is only converted once the sub-step that needs
    # its features has landed; anything unsupported falls back to the macro.
    def register_entry_info(fun, name, cname, trap, arg_types, arg_names, arg_decls)
        return nil if fun["selector"]          # dispatcher subtrap: 4a
        return nil if fun["variants"]          # flag trap + variants: 2d
        return nil if fun["executor_extras"]   # extras: 2c
        return nil unless cname == name        # all register traps are REGISTER_TRAP2
        args = (fun["args"] or [])
        return nil unless args.all? {|arg| arg["register"] }
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        conv = regcall_conv(fun)
        allowed_arg = /\A(D\d+|A\d+|TrapBit<[^>]*>|D0HighWord|D0LowWord)\z/
        return nil unless conv[:args].all? {|a| a && a =~ allowed_arg }
        return nil unless conv[:ret] =~ /\A(D\d+|A\d+|void)\z/
        { kind: :register, name: name, object: "stub_#{name}", impl: cname, trap: trap,
          ret: (fun["return"] or "void"), arg_types: arg_types, arg_names: arg_names,
          arg_decls: arg_decls, retconv: conv[:ret], argconvs: conv[:args],
          cc: register_cc(conv) }
    end

    def register_cc(conv)
        s = "callconv::Register<#{conv[:ret]}(#{conv[:args].join(', ')})"
        s += ", #{conv[:extras]}" if conv[:extras]
        s + ">"
    end

    # Local names used in the generated entrypoints, avoiding collisions with
    # the generated temporaries.
    RESERVED_LOCALS = ["addr", "retaddr", "ret", "argGetter", "logScope", "saveLR"]
    def entry_arg_names(arg_names)
        arg_names.map {|n| RESERVED_LOCALS.include?(n) ? "#{n}_arg" : n }
    end

    # The generated callable object + wrapper class, declared in the header.
    def emit_wrapper(e)
        upp = e[:cc].to_s.empty? ? "UPP<Sig>" : "UPP<Sig, #{e[:cc]}>"
        o = +""
        o << "namespace trapentries { struct Wrapper_#{e[:object]} : traps::GeneratedEntrypoint {\n"
        o << "    using Sig = #{e[:ret]}(#{e[:arg_types].join(', ')});\n"
        o << "    Wrapper_#{e[:object]}();\n"
        o << "    #{e[:ret]} operator()(#{e[:arg_decls].join(', ')}) const;\n"
        o << "    #{upp} operator&() const { return #{upp}(guestFunction()); }\n"
        o << "}; }\n"
        o << "extern trapentries::Wrapper_#{e[:object]} #{e[:object]};\n"
        o
    end

    def logging_call(name, callargs)
        a = callargs.empty? ? "" : ", #{callargs}"
        "#ifdef EXECUTOR_ENABLE_LOGGING\n" \
        "    logging::LogNestingScope logScope;\n" \
        "    if(logScope.active)\n" \
        "        logging::logTrapCall(\"#{name}\"#{a});\n" \
        "#endif\n"
    end

    def logging_return(name, ret, callargs)
        a = callargs.empty? ? "" : ", #{callargs}"
        if ret == "void"
            "#ifdef EXECUTOR_ENABLE_LOGGING\n" \
            "    if(logScope.active)\n" \
            "        logging::logTrapVoidReturn(\"#{name}\"#{a});\n" \
            "#endif\n"
        else
            "#ifdef EXECUTOR_ENABLE_LOGGING\n" \
            "    if(logScope.active)\n" \
            "        logging::logTrapValReturn(\"#{name}\", ret#{a});\n" \
            "#endif\n"
        end
    end

    # Straight-line 68K entrypoint.  Dispatches on the calling convention: the
    # Pascal form mirrors callconv::Pascal; the Register form mirrors
    # callfrom68K::Invoker + RegInvoker.
    def gen_68k_entry(e)
        return gen_68k_register_entry(e) if e[:kind] == :register

        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        o = +""
        o << "static syn68k_addr_t entry_#{e[:object]}(syn68k_addr_t addr [[maybe_unused]])\n"
        o << "{\n"
        o << "    syn68k_addr_t retaddr = callconv::stack::pop<syn68k_addr_t>();\n"
        e[:arg_types].each_with_index.to_a.reverse_each do |type, i|
            o << "    #{type} #{names[i]} = callconv::stack::pop<#{type}>();\n"
        end
        o << logging_call(e[:name], callargs)
        if e[:ret] == "void"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    #{e[:ret]} ret = #{e[:impl]}(#{callargs});\n"
        end
        o << logging_return(e[:name], e[:ret], callargs)
        o << "    *ptr_from_longint<GUEST<#{e[:ret]}>*>(EM_A7) = ret;\n" unless e[:ret] == "void"
        o << "    return retaddr;\n"
        o << "}\n\n"
        o
    end

    # Descriptor-driven 68K entrypoint for a Register-convention trap.  The
    # descriptors do the register/bit reads and conversions; this unrolls the
    # construct -> convert -> call -> set-return sequence.
    def gen_68k_register_entry(e)
        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        o = +""
        o << "static syn68k_addr_t entry_#{e[:object]}(syn68k_addr_t addr [[maybe_unused]])\n"
        o << "{\n"
        o << "    syn68k_addr_t retaddr = POPADDR();\n"
        e[:argconvs].each_with_index {|cc, i| o << "    callconv::#{cc} c#{i};\n" }
        e[:arg_types].each_with_index {|t, i| o << "    #{t} #{names[i]} = c#{i};\n" }
        o << logging_call(e[:name], callargs)
        if e[:ret] == "void"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    #{e[:ret]} ret = #{e[:impl]}(#{callargs});\n"
        end
        o << logging_return(e[:name], e[:ret], callargs)
        o << "    callconv::#{e[:retconv]}::set(ret);\n" unless e[:retconv] == "void"
        o << "    return retaddr;\n"
        o << "}\n\n"
        o
    end

    # Straight-line PowerPC entrypoint.  Reuses callfromPPC::ParameterPasser so
    # the register/spill ABI is identical to the old callfromPPC::Invoker path.
    def gen_ppc_entry(e)
        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        o = +""
        o << "static uint32_t entry_#{e[:object]}_ppc(PowerCore& cpu)\n"
        o << "{\n"
        o << "    uint32_t saveLR = cpu.lr;\n"
        o << "    EM_A7 = cpu.r[1];\n"
        unless e[:arg_types].empty?
            o << "    callfromPPC::ParameterPasser argGetter{cpu, guestvalues::GuestTypeTraits<uint8_t*>::reg_to_host(cpu.r[1] + 24)};\n"
            e[:arg_types].each_with_index do |type, i|
                o << "    #{type} #{names[i]};\n"
            end
            o << "    (void)(argGetter >> #{names.join(' >> ')});\n"
        end
        o << logging_call(e[:name], callargs)
        if e[:ret] == "void"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    #{e[:ret]} ret = #{e[:impl]}(#{callargs});\n"
        end
        o << logging_return(e[:name], e[:ret], callargs)
        o << "    callfromPPC::ParameterPasser{cpu, nullptr}.set(ret);\n" unless e[:ret] == "void"
        o << "    cpu.r[1] = EM_A7;\n"
        o << "    return saveLR;\n"
        o << "}\n\n"
        o
    end

    def gen_wrapper_methods(e)
        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        params = e[:arg_types].each_with_index.map {|t, i| "#{t} #{names[i]}" }.join(", ")
        upp = e[:cc].to_s.empty? ? "UPP<Sig>" : "UPP<Sig, #{e[:cc]}>"
        o = +""
        o << "Wrapper_#{e[:object]}::Wrapper_#{e[:object]}()\n"
        o << "    : traps::GeneratedEntrypoint(\"#{e[:name]}\", \"InterfaceLib\", #{hexlit(e[:trap])},\n"
        o << "                          &entry_#{e[:object]}, &entry_#{e[:object]}_ppc)\n"
        o << "{\n}\n\n"
        o << "#{e[:ret]} Wrapper_#{e[:object]}::operator()(#{params}) const\n"
        o << "{\n"
        if e[:ret] == "void"
            o << "    if(isPatched())\n"
            o << "    {\n"
            o << "        (#{upp}(SYN68K_TO_US(tableEntry())))(#{callargs});\n"
            o << "        return;\n"
            o << "    }\n"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    if(isPatched())\n"
            o << "        return (#{upp}(SYN68K_TO_US(tableEntry())))(#{callargs});\n"
            o << "    return #{e[:impl]}(#{callargs});\n"
        end
        o << "}\n\n"
        o
    end

    # Straight-line 68K/PowerPC entrypoints and wrapper objects for a module's
    # Pascal- and Register-convention traps.
    def generate_trap_entries(module_name, entries)
        out = +""
        out << "// Generated by make-multiverse.rb - DO NOT EDIT\n"
        out << "// Straight-line 68K/PowerPC entrypoints and wrapper objects.\n"
        out << "#include <base/functions.impl.h>\n"
        out << "#include <base/trap-entry.h>\n"
        out << "#include <base/logging.h>\n"
        out << "#include <#{module_name}.h>\n\n"
        out << "namespace Executor { namespace trapentries {\n\n"
        entries.each do |e|
            out << gen_68k_entry(e)
            out << gen_ppc_entry(e)
            out << gen_wrapper_methods(e)
        end
        out << "void ReferenceEntries_#{module_name}()\n{\n"
        entries.each {|e| out << "    (void)&entry_#{e[:object]};\n" }
        out << "}\n\n"
        out << "} }\n\n"
        out << "namespace Executor {\n"
        entries.each {|e| out << "trapentries::Wrapper_#{e[:object]} #{e[:object]};\n" }
        out << "}\n"
        out
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
        elsif value["callconv"] == "C" then
            @out << ", callconv::CCall"
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
        #if header.name == "MacTypes" then
        @out << "#include \"base/mactype.h\"\n"
        @out << "#include <cassert>\n"
        @out << "#include <iosfwd>\n"
        @out << "#include <base/lowglobals.h>\n"
        @out << "#include <base/trap-entry.h>\n"
        #end

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
        @entries = []
        result = super
        @entries_for_header = @entries
        result
    end

    def make_api_ifdef(api)
        if api == "carbon" then
        else
            yield
        end
    end

    def generate(defs)
        print "Writing Headers...\n"
        FileUtils.mkdir_p "#{$options.output_dir}/api"
        FileUtils.mkdir_p "#{$options.output_dir}/trap_instances"
        FileUtils.mkdir_p "#{$options.output_dir}/structdump"
        FileUtils.mkdir_p "#{$options.output_dir}/trap_entries"

        # A type can be defined in more than one module (e.g. an opaque QElem in
        # MacTypes and the full union in OSUtil); describe it only where it has
        # the fullest definition.
        best = {}
        defs.topsort.each do |name|
            name2 = remap_name(name)
            order, defs_here = struct_definitions(defs.headers[name])
            order.each do |tname|
                count = (defs_here[tname]["members"] || []).size
                best[tname] = [name2, count] if !best.key?(tname) || count > best[tname][1]
            end
        end

        moduleList = []
        entryModules = []
        defs.topsort.each do |name|
            name2 = remap_name(name)
            moduleList << name2
            header_text = generate_header(defs.headers[name])
            entries = @entries_for_header
            formatted_file "#{$options.output_dir}/api/#{name2}.h" do |f|
                f << header_text
            end
            formatted_file "#{$options.output_dir}/structdump/#{name2}.cpp" do |f|
                f << generate_structdump(defs.headers[name], name2, best)
            end
            formatted_file "#{$options.output_dir}/trap_entries/#{name2}.cpp" do |f|
                f << generate_trap_entries(name2, entries)
            end
            entryModules << name2
            formatted_file "#{$options.output_dir}/trap_instances/#{name2}.cpp" do |f|
                f << <<END
#define INSTANTIATE_TRAPS_#{name2}
#include <#{name2}.h>

// Function for preventing the linker from considering the static constructors in this module unused
namespace Executor::ReferenceTraps {
    void #{name2}() {}
}
END
            end
        end
        formatted_file "#{$options.output_dir}/trap_entries/ReferenceAllEntries.cpp" do |f|
            f << "// Generated by make-multiverse.rb - DO NOT EDIT\n"
            f << "namespace Executor { namespace trapentries {\n"
            entryModules.each { |m| f << "void ReferenceEntries_#{m}();\n" }
            f << "\nvoid ReferenceAllEntries() {\n"
            entryModules.each { |m| f << "    ReferenceEntries_#{m}();\n" }
            f << "}\n}}\n"
        end
        formatted_file "#{$options.output_dir}/trap_instances/ReferenceAllTraps.cpp" do |f|
            f << "namespace Executor {\n"
            f << "namespace ReferenceTraps {\n"
            moduleList.each { |m| f << "void #{m}();\n" }
            f << "}\nvoid ReferenceAllTraps() {\n"
            moduleList.each { |m| f << "ReferenceTraps::#{m}();\n" }
            f << "}\n}\n"
        end
        formatted_file "#{$options.output_dir}/structdump/ReferenceAllStructDumps.cpp" do |f|
            f << generate_reference_all_struct_dumps(moduleList)
        end
        File.open "#{$options.output_dir}/trap_instances/trap_instances.cmake", "w" do |f|
            f << "set(trap_instance_sources\n"
            f << "    \"#{$options.output_dir}/trap_instances/ReferenceAllTraps.cpp\"\n"
            moduleList.each { |m| f << "    \"#{$options.output_dir}/trap_instances/#{m}.cpp\"\n" }
            f << ")\n"
        end
        print "Done.\n"
    end
end