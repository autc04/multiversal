# Calling-convention model and the per-signature marshaller generators.
# Reopened onto ExecutorGenerator; loaded from executor.rb at the bottom.
#
# One `invokeUPP` / `createCallbackUPP` per distinct C++ signature.  The key is
# the emitted C++ type, not the YAML spelling: typedefs are transparent, so
# LONGINT/int32_t, MenuRef/MenuHandle, DialogPtr/WindowPtr and friends collapse.
# The definitions are emitted once, in the module that first declares the
# signature; every other module that mentions it gets declarations (repeating a
# declaration is harmless).
class ExecutorGenerator
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
    def register_cc(conv)
        s = "callconv::Register<#{conv[:ret]}(#{conv[:args].join(', ')})"
        s += ", #{conv[:extras]}" if conv[:extras]
        s + ">"
    end
    # Key used to deduplicate generated per-type argument/return printers.
    def log_type_key(type)
        "std::decay_t<#{type.to_s.strip}>"
    end
    def log_add_type(types, index, type)
        key = log_type_key(type)
        unless index.key?(key)
            index[key] = types.size
            types << key
        end
    end
    # One printer per distinct decayed argument/return type in a module, shared
    # by every trap that uses it, so that --logtraps instantiates no template
    # per trap: each entrypoint passes its values plus a pointer to the shared
    # printer table and a single non-template function formats them.
    def log_printer_types(entries, upp_defs, upp_ppc_defs)
        types = []
        index = {}
        entries.each do |e|
            next unless e[:kind] == :variant
            (e[:arg_types] || []).each {|t| log_add_type(types, index, t) }
            log_add_type(types, index, e[:ret]) if e[:ret] && e[:ret] != "void"
        end
        (upp_defs + upp_ppc_defs).each do |c|
            c[:args].each {|t| log_add_type(types, index, t) }
            log_add_type(types, index, c[:ret]) if c[:ret] != "void"
        end
        [types, index]
    end
    def log_values(args)
        return "" if args.empty?
        "        const void* lgvals[] = { #{args.map {|n| "&#{n}" }.join(", ")} };\n"
    end
    def log_call(name_expr, printer_table, args)
        o = +""
        o << "    logging::LogNestingScope logScope;\n"
        o << "    if(logScope.active)\n"
        o << "    {\n"
        o << log_values(args)
        if args.empty?
            o << "        logging::logTrapCallData(#{name_expr}, nullptr, nullptr, 0);\n"
        else
            o << "        logging::logTrapCallData(#{name_expr}, #{printer_table}, lgvals, #{args.size});\n"
        end
        o << "    }\n"
        o
    end
    def log_return(name_expr, printer_table, ret, args, qualifier: "")
        values = args.empty? ? "nullptr, nullptr, 0" : "#{printer_table}, lgvals, #{args.size}"
        o = +""
        o << "    if(logScope.active)\n"
        o << "    {\n"
        o << log_values(args)
        if ret == "void"
            o << "        logging::logTrapVoidReturnData(#{name_expr}, #{values});\n"
        else
            o << "        logging::logTrapValReturnData(#{name_expr}, #{qualifier}logArg_#{@log_index[log_type_key(ret)]}, &ret, #{values});\n"
        end
        o << "    }\n"
        o
    end
    def emit_log_printer_table(out, name, types)
        return if types.empty?
        out << "static const logging::LogArgFn #{name}[] = { "
        out << types.map {|t| "logArg_#{@log_index[log_type_key(t)]}" }.join(", ")
        out << " };\n"
    end
    def declare_funptr(value)
        name = value["name"]
        args = (value["args"] or [])

        @out << "using #{name} = UPP<"
        @out << (value["return"] or "void") << "("
        args = (value["args"] or [])
        @out << args.map {|arg|decl(arg["type"], arg["name"])}.join(", ")
        @out << ")"
        cc, conv = funptr_callconv(value)
        if cc.start_with?("callconv::Register<")
            @out << ", Register<"
            handle_regcall_conv(value)
            @out << ">"
        elsif cc == "callconv::CCall" then
            @out << ", callconv::CCall"
        end
        @out << ">;\n"

        register_upp_candidate((value["return"] or "void"),
                               args.map {|arg| decl(arg["type"], "").strip},
                               cc, conv: conv)
    end
    def register_upp_candidate(ret, arg_types, cc, conv: nil)
        @upp_pending << { ret: ret, args: arg_types, cc: cc, conv: conv }
    end
    # The UPP convention of a funptr or executor_marshaling declaration: the
    # emitted `cc` string plus the decomposed 68K convention (nil for
    # Pascal/CCall).  The 68K marshaller body is generated from the latter.
    def funptr_callconv(value)
        args = (value["args"] or [])
        if value["returnreg"] || value["executor_extras"] || args.any? {|arg| arg["register"]}
            conv = regcall_conv(value)
            [register_cc(conv),
             { ret: conv[:ret], args: conv[:args],
               extras: (conv[:extras] || "").split(",").map(&:strip).reject(&:empty?) }]
        elsif value["callconv"] == "C"
            ["callconv::CCall", nil]
        else
            ["", nil]
        end
    end
    def canon_cc(cc)
        cc.to_s.sub(/\Acallconv::/, "").gsub(/\s+/, "")
    end
    def canon_type(type, param: false, seen: [])
        t = type.to_s.strip
        return "void" if t.empty?

        is_const = false
        if t =~ /\Aconst\s+(.*)\z/
            is_const = true
            t = $1.strip
        elsif t =~ /\A(.*?)\s+const\z/
            is_const = true
            t = $1.strip
        end
        prefix = is_const ? "const " : ""

        if t =~ /\A(.*?)\s*(\[[^\]]*\])\z/
            base, suffix = $1.strip, $2
            return prefix + canon_type(base, param: false, seen: seen) + (param ? "*" : suffix)
        end

        if t =~ /\A(.*?)\s*\*\z/
            return prefix + canon_type($1.strip, param: false, seen: seen) + "*"
        end

        if t =~ /\AGUEST<\s*(.*?)\s*>\z/
            inner = canon_type($1.strip, param: false, seen: seen)
            # GuestType<T> is T for GUEST_STRUCT types, so GUEST<Struct> and
            # Struct are the same C++ type.
            if @noguest_types && inner != "void" && @noguest_types.include?(inner)
                return prefix + inner
            end
            return prefix + "GUEST<" + inner + ">"
        end

        if @typedef_emitted && @typedef_emitted.key?(t)
            raise "typedef cycle through #{t}" if seen.include?(t)
            return prefix + canon_type(@typedef_emitted[t], param: param, seen: seen + [t])
        end

        builtin = {
            "signed char" => "int8_t",
            "unsigned char" => "uint8_t",
            "signed short" => "int16_t",
            "unsigned short" => "uint16_t",
            "signed int" => "int32_t",
            "unsigned int" => "uint32_t",
        }[t] || t
        prefix + builtin.gsub(/\s+/, " ")
    end
    def upp_sig_key(c)
        [canon_type(c[:ret]),
         c[:args].map {|a| canon_type(a, param: true) }]
    end
    def upp_key(c)
        (upp_sig_key(c) + [canon_cc(c[:cc])]).join(" | ")
    end
    # The PPC marshaller is keyed on the signature alone; the 68K calling
    # convention (register/extras descriptors) does not exist on PowerPC.
    def upp_ppc_key(c)
        upp_sig_key(c).join(" | ")
    end
    def upp_cc_type(c)
        c[:cc].to_s.empty? ? "callconv::Pascal" : c[:cc]
    end
    def upp_type_for(ret, args, cc)
        cc = cc.to_s.empty? ? "" : ", #{cc}"
        "UPP<#{ret}(#{args.join(', ')})#{cc}>"
    end
    def upp_type(c)
        upp_type_for(c[:ret], c[:args], c[:cc])
    end
    # The same type written from the canonical spelling.  Used to check that a
    # spelling was merged (or kept apart) for the right reason: it is emitted in
    # the spelling's own module, so every name in it is in scope.
    def upp_canonical_type(c)
        upp_type_for(canon_type(c[:ret]),
                     c[:args].map {|a| canon_type(a, param: true) },
                     c[:cc])
    end
    def upp_params(c)
        c[:args].each_with_index.map {|t, i| "#{t} a#{i}" }.join(", ")
    end
    def upp_arglist(c)
        c[:args].each_index.map {|i| "a#{i}" }
    end
    def upp_is_ccall?(c)
        canon_cc(c[:cc]) == "CCall"
    end
    def upp_printer_name(id_key, c)
        id_key == :ppc_id ? "trapentries::logPrintersUppPpc_#{c[:ppc_id]}" : "trapentries::logPrintersUpp_#{c[:upp_id]}"
    end
    def upp_68k_definition(c)
        names = upp_arglist(c)
        ret = c[:ret]
        args = c[:args]
        conv = c[:conv]
        o = +""
        o << "syn68k_addr_t invokeFrom68K(syn68k_addr_t addr [[maybe_unused]], "
        o << "#{ret} (*f)(#{args.join(', ')}), traps::Entrypoint* ep, const #{upp_cc_type(c)}*)\n"
        o << "{\n"
        if conv
            extras = conv[:extras] || []
            extras.each_with_index {|x, i| o << "    #{x} e#{i};\n" }
            o << "    syn68k_addr_t retaddr = POPADDR();\n"
            conv[:args].each_with_index {|cc, i| o << "    callconv::#{cc} c#{i};\n" }
            args.each_with_index {|t, i| o << "    std::decay_t<#{t}> #{names[i]} = c#{i};\n" }
            o << log_call("ep->name", upp_printer_name(:upp_id, c), names)
            if ret == "void"
                o << "    f(#{names.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{names.join(', ')});\n"
            end
            o << log_return("ep->name", upp_printer_name(:upp_id, c), ret, names, qualifier: "trapentries::")
            o << "    callconv::#{conv[:ret]}::set(ret);\n" unless conv[:ret] == "void"
            if extras.empty?
                o << "    return retaddr;\n"
            else
                o << "    syn68k_addr_t r = retaddr;\n"
                extras.each_index.to_a.reverse_each {|i| o << "    r = e#{i}.afterwards(r);\n" }
                o << "    return r;\n"
            end
        elsif upp_is_ccall?(c)
            unless args.empty?
                o << "    std::tuple<#{args.join(', ')}> args;\n"
                o << "    syn68k_addr_t p = EM_A7 + 4;\n"
                args.each_index {|i| o << "    callconv::readCArg(std::get<#{i}>(args), p);\n" }
            end
            values = args.each_index.map {|i| "std::get<#{i}>(args)" }
            o << log_call("ep->name", upp_printer_name(:upp_id, c), values)
            if ret == "void"
                o << "    f(#{values.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{values.join(', ')});\n"
            end
            o << log_return("ep->name", upp_printer_name(:upp_id, c), ret, values, qualifier: "trapentries::")
            o << "    EM_D0 = ret;\n" unless ret == "void"
            o << "    return callconv::stack::pop<syn68k_addr_t>();\n"
        else
            o << "    syn68k_addr_t retaddr = callconv::stack::pop<syn68k_addr_t>();\n"
            args.each_with_index.to_a.reverse_each do |t, i|
                o << "    std::decay_t<#{t}> #{names[i]} = callconv::stack::pop<std::decay_t<#{t}>>();\n"
            end
            o << log_call("ep->name", upp_printer_name(:upp_id, c), names)
            if ret == "void"
                o << "    f(#{names.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{names.join(', ')});\n"
            end
            o << log_return("ep->name", upp_printer_name(:upp_id, c), ret, names, qualifier: "trapentries::")
            o << "    *ptr_from_longint<GUEST<#{ret}>*>(EM_A7) = ret;\n" unless ret == "void"
            o << "    return retaddr;\n"
        end
        o << "}\n\n"
        o
    end
    def upp_ppc_definition(c)
        names = upp_arglist(c)
        ret = c[:ret]
        args = c[:args]
        o = +""
        o << "uint32_t invokeFromPPC(PowerCore& cpu, "
        o << "#{ret} (*f)(#{args.join(', ')}), traps::Entrypoint* ep)\n"
        o << "{\n"
        o << "    uint32_t saveLR = cpu.lr;\n"
        o << "    EM_A7 = cpu.r[1];\n"
        unless args.empty?
            o << "    callfromPPC::ParameterPasser argGetter{cpu, guestvalues::GuestTypeTraits<uint8_t*>::reg_to_host(cpu.r[1] + 24)};\n"
            args.each_with_index {|t, i| o << "    std::decay_t<#{t}> #{names[i]};\n" }
            o << "    (void)(argGetter >> #{names.join(' >> ')});\n"
        end
        o << log_call("ep->name", upp_printer_name(:ppc_id, c), names)
        if ret == "void"
            o << "    f(#{names.join(', ')});\n"
        else
            o << "    #{ret} ret = f(#{names.join(', ')});\n"
        end
        o << log_return("ep->name", upp_printer_name(:ppc_id, c), ret, names, qualifier: "trapentries::")
        o << "    callfromPPC::ParameterPasser{cpu, nullptr}.set(ret);\n" unless ret == "void"
        o << "    cpu.r[1] = EM_A7;\n"
        o << "    return saveLR;\n"
        o << "}\n\n"
        o
    end
    def upp_call_definition(c)
        return "" if upp_is_ccall?(c)
        names = upp_arglist(c)
        ret = c[:ret]
        conv = c[:conv]
        o = +""
        o << "#{ret} invokeUPP(const #{upp_type(c)}& f"
        o << ", #{upp_params(c)}" unless c[:args].empty?
        o << ")\n{\n"
        if conv
            conv[:args].each_with_index do |cc, i|
                o << "    callconv::#{cc}::set(#{names[i]});\n"
            end
            o << "    execute68K(US_TO_SYN68K(f.ptr));\n"
            conv[:args].each_index.to_a.reverse_each do |i|
                o << "    callconv::#{conv[:args][i]}::afterCall(#{names[i]});\n"
            end
            o << "    return callconv::#{conv[:ret]}();\n" unless conv[:ret] == "void"
        else
            o << "    callconv::stack::push(std::decay_t<#{ret}>());\n" unless ret == "void"
            names.each {|n| o << "    callconv::stack::push(#{n});\n" }
            o << "    M68kReg saveregs[14];\n"
            o << "    memcpy(saveregs, &EM_D1, sizeof(saveregs)); /* d1-d7/a0-a6 */\n"
            o << "    execute68K(US_TO_SYN68K(f.ptr));\n"
            o << "    memcpy(&EM_D1, saveregs, sizeof(saveregs)); /* d1-d7/a0-a6 */\n"
            o << "    return callconv::stack::pop<#{ret}>();\n" unless ret == "void"
        end
        o << "}\n\n"
        o
    end
    def upp_callback_definition(c)
        t = upp_type(c)
        o = +""
        o << "void createCallbackUPP(#{c[:ret]} (*f)(#{c[:args].join(', ')}), #{t}& out, traps::Entrypoint* ep)\n{\n"
        o << "    out = #{t}(SYN68K_TO_US(traps::callback_install(\n"
        o << "        [f, ep](syn68k_addr_t addr)\n"
        o << "        {\n"
        o << "            if(auto ret = ep->checkBreak68K(addr); ~ret)\n"
        o << "                return ret;\n"
        o << "            return invokeFrom68K(addr, f, ep, (const #{upp_cc_type(c)}*)nullptr);\n"
        o << "        })));\n"
        o << "}\n\n"
        o
    end
    def upp_68k_definitions(c)
        upp_68k_definition(c) + upp_call_definition(c) + upp_callback_definition(c)
    end
    def upp_declarations(local_reps)
        o = +""
        seen_ppc = Set.new
        local_reps.each_value do |c|
            t = upp_type(c)
            o << "syn68k_addr_t invokeFrom68K(syn68k_addr_t, #{c[:ret]} (*)(#{c[:args].join(', ')}), traps::Entrypoint*, const #{upp_cc_type(c)}*);\n"
            ppc_key = upp_ppc_key(c)
            unless seen_ppc.include?(ppc_key)
                seen_ppc << ppc_key
                o << "uint32_t invokeFromPPC(PowerCore&, #{c[:ret]} (*)(#{c[:args].join(', ')}), traps::Entrypoint*);\n"
            end
            unless upp_is_ccall?(c)
                o << "#{c[:ret]} invokeUPP(const #{t}& f"
                o << ", #{upp_params(c)}" unless c[:args].empty?
                o << ");\n"
            end
            o << "void createCallbackUPP(#{c[:ret]} (*f)(#{c[:args].join(', ')}), "
            o << "#{t}& out, traps::Entrypoint* ep);\n"
        end
        o
    end
end
