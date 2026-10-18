# Trap/entrypoint declaration and straight-line entrypoint generation for
# Executor.
#
# Reopens ExecutorGenerator; loaded from executor.rb.

class ExecutorGenerator
    # Selector-location names the generated dispatcher can describe as data
    # (kind, mask) instead of a template parameter.
    SELECTOR_KINDS = {
        "D0W" => ["D0", 0xFFFF],
        "D0L" => ["D0", 0xFFFFFFFF],
        "StackW" => ["StackWMasked", 0xFFFF],
        "StackL" => ["StackLMasked", 0xFFFFFFFF],
        "TrapBits" => ["D1", 0x600],
    }
    def selector_kind_masked(loc)
        return SELECTOR_KINDS[loc] if SELECTOR_KINDS.key?(loc)
        if loc =~ /\A(D0|D1|StackWMasked|StackLMasked|StackWLookahead)<(0x[0-9A-Fa-f]+)>\z/
            return [$1, Integer($2)]
        end
        nil
    end

    def declare_dispatcher(value, extern:false)
        @available_dispatchers << value["name"]
        name = value["name"]
        conv = selector_kind_masked(value["selector-location"])
        unless conv
            raise "unhandled dispatcher selector-location #{value["selector-location"]} for #{name}"
        end
        @out << "extern traps::GeneratedDispatcherTrap #{name};\n"
        return if extern
        @entries << { kind: :dispatcher, name: name, object: name, trap: value["trap"],
                      selkind: conv[0], selmask: conv[1] }
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
                declare_notrap("LMGet#{value["name"]}", "void",
                               [decl(value["type"]+"*", "").strip], ["val"],
                               [decl(value["type"]+"*", "val")])
                declare_notrap("LMSet#{value["name"]}", "void",
                               [decl("const " + value["type"]+"*", "").strip], ["val"],
                               [decl("const " + value["type"]+"*", "val")])
            else
                @out << "inline #{decl(value["type"])} LMGet#{value["name"]}() { return LM(#{value["name"]}); }\n"
                @out << "inline void LMSet#{value["name"]}(#{decl(value["type"],"val")}) { LM(#{value["name"]}) = val; }\n"
                declare_notrap("LMGet#{value["name"]}", decl(value["type"]).strip, [], [], [])
                declare_notrap("LMSet#{value["name"]}", "void",
                               [decl(value["type"], "").strip], ["val"],
                               [decl(value["type"], "val")])
            end
    end

    end

    # A function published to the guest but not installed as a trap
    # (NOTRAP_FUNCTION / NOTRAP_FUNCTION2).  It still creates a guest-callable
    # entrypoint and registers itself for PPC and for the debugger.
    def notrap_entry_info(name, cname, ret, arg_types, arg_names, arg_decls)
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        object = (name == cname) ? "stub_#{name}" : name
        { kind: :notrap, name: name, object: object, impl: cname, trap: 0, ret: ret,
          arg_types: arg_types, arg_names: arg_names, arg_decls: arg_decls, cc: "" }
    end

    def declare_notrap(name, ret, arg_types, arg_names, arg_decls)
        info = notrap_entry_info(name, name, ret, arg_types, arg_names, arg_decls)
        raise "unhandled notrap #{name}" if !info
        @out << emit_wrapper(info)
        @entries << info
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

        # A raw 68K entry: the implementation is a hand-written
        # syn68k_addr_t RAW_<name>(syn68k_addr_t) function, and the wrapper
        # object is stub_<name>.
        if fun["executor_raw"] then
            @out << "syn68k_addr_t RAW_#{name}(syn68k_addr_t);"
            info = { kind: :raw, name: name, object: "stub_#{name}", impl: "RAW_#{name}",
                     trap: (trap or 0), cc: "" }
            @out << emit_wrapper(info)
            @entries << info
            return
        end

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

        @out << (fun["return"] or "void") << " " << cname

        args = (fun["args"] or [])

        arg_decls = args.map {|arg| decl(arg["type"], arg["name"])}
        @out << "(" << arg_decls.join(", ") << ");"

        # Argument types without names, captured here so the entrypoint
        # generator sees the same GUEST<>-ness the declaration got.
        arg_types = args.map {|arg| decl(arg["type"], "").strip}
        arg_names = args.each_with_index.map {|arg, i| arg["name"] || "arg#{i}"}

        if fun["selector"] then
            sub = "SUB"
        else
            sub = ""
        end

        if not fun["executor"]
            if fun["executor_marshaling"] then
                cc, conv = funptr_callconv(fun)
                register_upp_candidate((fun["return"] or "void"), arg_types,
                                       cc, conv: conv)
            end
        elsif fun["file_trap"] == "mfs" then
        elsif fun["file_trap"] == "hfs" then
            infos = file_entry_infos(fun, name, cname, trap, arg_types, arg_names, arg_decls)
            if infos then
                infos.each {|e| @out << emit_wrapper(e); @entries << e }
            else
                raise "unhandled HFS trap #{name} (#{sub})"
            end
        elsif fun["file_trap"] then
            infos = file_entry_infos(fun, name, cname, trap, arg_types, arg_names, arg_decls)
            if infos then
                infos.each {|e| @out << emit_wrapper(e); @entries << e }
            else
                raise "unhandled file trap #{name} (#{sub})"
            end
        elsif trap && (fun["executor_extras"] || fun["returnreg"] || args.any? {|arg| arg["register"]}) then
            info = register_entry_info(fun, name, cname, trap, arg_types, arg_names, arg_decls)
            if info then
                @out << emit_wrapper(info)
                @entries << info
                register_variant_infos(fun, info[:object], arg_types, arg_names, arg_decls).each do |v|
                    @out << emit_wrapper(v)
                    @entries << v
                end
            else
                raise "unhandled flag/Register trap #{name}"
            end
        elsif fun["selector"] then
            ret = (fun["return"] or "void")
            info = pascal_sub_info(fun, name, cname, trap, ret, arg_types, arg_names, arg_decls)
            if info then
                @out << emit_wrapper(info)
                @entries << info
            else
                raise "unhandled Pascal subtrap #{name}"
            end
        elsif trap then
            if name == cname then
                info = register_entry_info(fun, name, cname, trap, arg_types, arg_names, arg_decls)
                if info then
                    @out << emit_wrapper(info)
                    @entries << info
                elsif args.size == 0 && !fun["return"] then
                    raise "unhandled void Register trap #{name}"
                else
                    raise "unhandled Register trap2 #{name}"
                end
            else
                ret = (fun["return"] or "void")
                info = pascal_entry_info(name, cname, trap, ret, arg_types, arg_names, arg_decls)
                if info then
                    @out << emit_wrapper(info)
                    @entries << info
                else
                    raise "unhandled Pascal trap #{name}"
                end
            end
        else
            ret = (fun["return"] or "void")
            info = notrap_entry_info(name, cname, ret, arg_types, arg_names, arg_decls)
            if info then
                @out << emit_wrapper(info)
                @entries << info
            else
                raise "unhandled notrap function #{name}"
            end
        end
    end

    def pascal_entry_info(name, cname, trap, ret, arg_types, arg_names, arg_decls)
        return nil unless cname == "C_" + name
        # Types with commas or brackets can't be a single template argument.
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        { kind: :pascal, name: name, object: name, impl: cname, trap: trap, ret: ret,
          arg_types: arg_types, arg_names: arg_names, arg_decls: arg_decls, cc: "" }
    end

    # A Pascal-convention dispatcher subtrap (PASCAL_SUBTRAP): registered into a
    # GenericDispatcherTrap under a selector instead of a trap-table slot.
    def pascal_sub_info(fun, name, cname, trap, ret, arg_types, arg_names, arg_decls)
        return nil unless fun["dispatcher"] && fun["selector"]
        return nil unless cname == "C_" + name
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        { kind: :sub, name: name, object: name, impl: cname, trap: trap, ret: ret,
          arg_types: arg_types, arg_names: arg_names, arg_decls: arg_decls, cc: "",
          dispatcher: fun["dispatcher"], selector: hexlit(fun["selector"]) }
    end

    # A Register-convention trap is only converted once the sub-step that needs
    # its features has landed; anything unsupported falls back to the macro.
    def register_entry_info(fun, name, cname, trap, arg_types, arg_names, arg_decls)
        if fun["variants"] && !fun["selector"]
            return nil unless [2, 4].include?(fun["variants"].size)
        end
        extras = (fun["executor_extras"] or "").split(",").map(&:strip).reject(&:empty?)
        return nil unless extras.all? do |x|
            x =~ /\A(callconv::)?(ReturnMemErr|ReturnMemErrConditional|SaveA1D1D2|ClearD0|CCFromD0|MoveA1ToA0)(<[^>]*>)?\z/
        end
        args = (fun["args"] or [])
        return nil unless args.all? {|arg| arg["register"] }
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }
        conv = regcall_conv(fun)
        allowed_arg = /\A(D\d+|A\d+|TrapBit<[^>]*>|D0HighWord|D0LowWord|Out<[^>]*>|InOut<[^>]*>)\z/
        return nil unless conv[:args].all? {|a| a && a =~ allowed_arg }
        return nil unless conv[:ret] =~ /\A(D\d+|A\d+|void|D0Minus1Boolean)\z/
        # Object/Entrypoint naming follows the macro: flag traps pass cname as
        # IMPL_NAME; subtraps and plain register traps pass name.  REGISTER_TRAP2
        # (name == cname) makes stub_<name>, REGISTER_TRAP/SUBTRAP make <name>.
        ename = fun["variants"] ? cname : name
        object = fun["variants"] ? "stub_#{cname}" : ((name == cname) ? "stub_#{name}" : name)
        info = { kind: :register, name: ename, object: object, impl: cname, trap: trap,
                 ret: (fun["return"] or "void"), arg_types: arg_types, arg_names: arg_names,
                 arg_decls: arg_decls, retconv: conv[:ret], argconvs: conv[:args],
                 extras: extras, cc: register_cc(conv) }
        if fun["selector"]
            info[:dispatcher] = fun["dispatcher"]
            info[:selector] = hexlit(fun["selector"])
        end
        info
    end

    # The PPC-only adapter objects for a flag trap (NewHandle, NewHandleClear,
    # ...): each forwards to the stub with its flag arguments bound.
    def register_variant_infos(fun, stub_object, arg_types, arg_names, arg_decls)
        variants = fun["variants"]
        return [] unless variants
        return [] if fun["selector"]
        nflags = variants.size >= 3 ? 2 : 1
        k = (fun["args"] or []).size - nflags
        return [] if k < 0
        a_types = arg_types[0...k]
        a_names = arg_names[0...k]
        a_decls = arg_decls[0...k]
        return [] if a_types.any? {|t| t =~ /[,\[\]()]/ }
        # REGISTER_2FLAG_TRAP expands TRAP_VARIANT in the order
        # NAME00(ff), NAME10(tf), NAME01(ft), NAME11(tt) but takes the names
        # positionally as NAME00, NAME01, NAME10, NAME11, i.e. the i-th name
        # gets flags (i&2, i&1).
        flag_sets = variants.size >= 3 ? [[false, false], [false, true], [true, false], [true, true]]
                                      : [[false], [true]]
        variants.each_with_index.map do |vname, i|
            { kind: :variant, name: vname, object: vname, impl: vname, trap: 0,
              ret: (fun["return"] or "void"), arg_types: a_types, arg_names: a_names,
              arg_decls: a_decls, target: stub_object, flags: flag_sets[i], cc: "" }
        end
    end

    # FILE_TRAP / HFS_TRAP (non-subtrap) as generated entries: a stub wrapping
    # the (possibly generated) implementation plus the Sync/Async variant
    # adapters.  Mirrors the FILE_TRAP / HFS_TRAP macros.
    def file_entry_infos(fun, name, cname, trap, arg_types, arg_names, arg_decls)
        ft = fun["file_trap"]
        return nil unless ft
        return nil if ft == "mfs"                   # emits only the declaration
        return nil unless cname == name
        args = (fun["args"] or [])
        return nil if args.size < 2
        return nil if arg_types.any? {|t| t =~ /[,\[\]()]/ }

        if fun["selector"] && ft != "hfs"
            # FILE_SUBTRAP: REGISTER_SUBTRAP2 under a selector, plus Sync/Async.
            stub = { kind: :register, name: name, object: "stub_#{name}", impl: name,
                     trap: trap, ret: "OSErr", arg_types: arg_types, arg_names: arg_names,
                     arg_decls: arg_decls, retconv: "D0", argconvs: ["A0", "TrapBit<ASYNCBIT>"],
                     extras: [], cc: "callconv::Register<D0(A0, TrapBit<ASYNCBIT>)>",
                     dispatcher: fun["dispatcher"], selector: hexlit(fun["selector"]) }
            k = arg_types.size - 1
            variants = ["#{name}Sync", "#{name}Async"].each_with_index.map do |vn, i|
                { kind: :variant, name: vn, object: vn, impl: vn, trap: 0, ret: "OSErr",
                  arg_types: arg_types[0...k], arg_names: arg_names[0...k],
                  arg_decls: arg_decls[0...k], target: stub[:object],
                  flags: (i == 0 ? [false] : [true]), cc: "" }
            end
            return [stub] + variants
        end

        if ft == "hfs"
            base = name.gsub(/^PBH/, "PB")
            pbtype = args[0]["type"]
            t = Integer(trap) & 0xA0FF
            helper = +""
            helper << "static OSErr #{base}_#{name}(ParmBlkPtr pb, Boolean async, Boolean hfs)\n"
            helper << "{\n"
            helper << "    return hfs ? #{name}((#{pbtype})pb, async) : #{base}(pb, async);\n"
            helper << "}\n\n"
            stub = { kind: :register, name: "#{base}/#{name}", object: "stub_#{base}",
                     impl: "#{base}_#{name}", trap: t, ret: "OSErr",
                     arg_types: ["ParmBlkPtr", "Boolean", "Boolean"],
                     arg_names: ["pb", "async", "hfs"],
                     arg_decls: ["ParmBlkPtr pb", "Boolean async", "Boolean hfs"],
                     retconv: "D0", argconvs: ["A0", "TrapBit<ASYNCBIT>", "TrapBit<HFSBIT>"],
                     extras: [], cc: "callconv::Register<D0(A0, TrapBit<ASYNCBIT>, TrapBit<HFSBIT>)>",
                     helper: helper }
            # HFS_SUBTRAP: the same stub, but registered under a dispatcher
            # selector instead of a trap-table slot.
            if fun["selector"]
                stub[:dispatcher] = fun["dispatcher"]
                stub[:selector] = hexlit(fun["selector"])
            end
            vnames = ["#{base}Sync", "#{base}Async", "#{name}Sync", "#{name}Async"]
            vtypes = ["ParmBlkPtr", "ParmBlkPtr", "HParmBlkPtr", "HParmBlkPtr"]
            vflags = [[false, false], [true, false], [false, true], [true, true]]
        else
            stub = { kind: :register, name: name, object: "stub_#{name}", impl: name,
                     trap: trap, ret: "OSErr", arg_types: arg_types, arg_names: arg_names,
                     arg_decls: arg_decls, retconv: "D0", argconvs: ["A0", "TrapBit<ASYNCBIT>"],
                     extras: [], cc: "callconv::Register<D0(A0, TrapBit<ASYNCBIT>)>" }
            vnames = ["#{name}Sync", "#{name}Async"]
            vtypes = ["ParmBlkPtr", "ParmBlkPtr"]
            vflags = [[false], [true]]
        end

        variants = vnames.each_with_index.map do |vn, i|
            { kind: :variant, name: vn, object: vn, impl: vn, trap: 0, ret: "OSErr",
              arg_types: [vtypes[i]], arg_names: ["pb"], arg_decls: ["#{vtypes[i]} pb"],
              target: stub[:object], flags: vflags[i], cast_types: ["ParmBlkPtr"], cc: "" }
        end
        [stub] + variants
    end

    # Local names used in the generated entrypoints, avoiding collisions with
    # the generated temporaries.
    RESERVED_LOCALS = ["addr", "retaddr", "ret", "argGetter", "logScope", "saveLR"]
    def entry_arg_names(arg_names)
        arg_names.map {|n| RESERVED_LOCALS.include?(n) ? "#{n}_arg" : n }
    end

    # The generated callable object + wrapper class, declared in the header.
    def emit_wrapper(e)
        if e[:kind] == :raw
            o = +""
            o << "namespace trapentries { struct Wrapper_#{e[:object]} : traps::GeneratedEntrypoint {\n"
            o << "    Wrapper_#{e[:object]}();\n"
            o << "    ProcPtr operator&() const { return guestFunction(); }\n"
            o << "}; }\n"
            o << "extern trapentries::Wrapper_#{e[:object]} #{e[:object]};\n"
            return o
        end
        if e[:kind] == :variant
            o = +""
            o << "namespace trapentries { struct Wrapper_#{e[:object]} : traps::GeneratedEntrypoint {\n"
            o << "    Wrapper_#{e[:object]}();\n"
            o << "    #{e[:ret]} operator()(#{e[:arg_decls].join(', ')}) const;\n"
            o << "}; }\n"
            o << "extern trapentries::Wrapper_#{e[:object]} #{e[:object]};\n"
            return o
        end

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

    # PowerPC adapter for a PPC-only variant entry.  Typed traps use the
    # per-signature invokeFromPPC marshaller from their constructor instead.
    def gen_ppc_entry(e)
        return "" unless e[:kind] == :variant
        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        o = +""
        o << "static uint32_t entry_#{e[:object]}_ppc(PowerCore& cpu [[maybe_unused]], traps::Entrypoint* ep [[maybe_unused]])\n"
        o << "{\n"
        o << "    uint32_t saveLR = cpu.lr;\n"
        o << "    EM_A7 = cpu.r[1];\n"
        unless e[:arg_types].empty?
            o << "    callfromPPC::ParameterPasser argGetter{cpu, guestvalues::GuestTypeTraits<uint8_t*>::reg_to_host(cpu.r[1] + 24)};\n"
            e[:arg_types].each_with_index do |type, i|
                o << "    std::decay_t<#{type}> #{names[i]};\n"
            end
            o << "    (void)(argGetter >> #{names.join(' >> ')});\n"
        end
        o << log_call("\"#{e[:name]}\"", "logPrinters_#{e[:object]}", names)
        if e[:ret] == "void"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    #{e[:ret]} ret = #{e[:impl]}(#{callargs});\n"
        end
        o << log_return("\"#{e[:name]}\"", "logPrinters_#{e[:object]}", e[:ret], names)
        o << "    callfromPPC::ParameterPasser{cpu, nullptr}.set(ret);\n" unless e[:ret] == "void"
        o << "    cpu.r[1] = EM_A7;\n"
        o << "    return saveLR;\n"
        o << "}\n\n"
        o
    end

    # The two non-capturing entry lambdas passed to GeneratedEntrypoint.  They
    # name the trap implementation so its type is checked against the
    # signature's marshaller, with no erased implementation pointer.
    def entry_lambdas(e)
        cc = upp_cc_type(e)
        o = +""
        o << "                          [](syn68k_addr_t addr, traps::Entrypoint* ep) -> syn68k_addr_t\n"
        o << "                          {\n"
        o << "                              return invokeFrom68K(addr, &#{e[:impl]}, ep, (const #{cc}*)nullptr);\n"
        o << "                          },\n"
        o << "                          [](PowerCore& cpu, traps::Entrypoint* ep) -> uint32_t\n"
        o << "                          {\n"
        o << "                              return invokeFromPPC(cpu, &#{e[:impl]}, ep);\n"
        o << "                          }"
        o
    end

    def gen_wrapper_methods(e)
        if e[:kind] == :raw
            o = +""
            o << "Wrapper_#{e[:object]}::Wrapper_#{e[:object]}()\n"
            o << "    : traps::GeneratedEntrypoint(\"#{e[:name]}\", nullptr, #{hexlit(e[:trap])},\n"
            o << "                          [](syn68k_addr_t addr, traps::Entrypoint* ep) -> syn68k_addr_t\n"
            o << "                          {\n"
            o << "                              return invokeFromRaw68K(addr, &#{e[:impl]}, ep);\n"
            o << "                          }, nullptr)\n"
            o << "{\n}\n\n"
            return o
        end
        names = entry_arg_names(e[:arg_names])
        callargs = names.join(", ")
        params = e[:arg_types].each_with_index.map {|t, i| "#{t} #{names[i]}" }.join(", ")
        if e[:kind] == :variant
            o = +""
            o << "Wrapper_#{e[:object]}::Wrapper_#{e[:object]}()\n"
            o << "    : traps::GeneratedEntrypoint(\"#{e[:name]}\", \"InterfaceLib\", 0, nullptr,\n"
            o << "                          &entry_#{e[:object]}_ppc)\n"
            o << "{\n}\n\n"
            o << "#{e[:ret]} Wrapper_#{e[:object]}::operator()(#{params}) const\n"
            o << "{\n"
            fwd = names.each_with_index.map {|n, i|
                e[:cast_types] ? "(#{e[:cast_types][i]})#{n}" : n
            }.join(", ")
            argstr = fwd.empty? ? "" : "#{fwd}, "
            flagstr = e[:flags].map {|f| f ? "true" : "false" }.join(", ")
            if e[:ret] == "void"
                o << "    #{e[:target]}(#{argstr}#{flagstr});\n"
            else
                o << "    return #{e[:target]}(#{argstr}#{flagstr});\n"
            end
            o << "}\n\n"
            return o
        end

        if e[:kind] == :sub || e[:dispatcher]
            o = +""
            o << "Wrapper_#{e[:object]}::Wrapper_#{e[:object]}()\n"
            o << "    : traps::GeneratedEntrypoint(\"#{e[:name]}\", \"InterfaceLib\", 0,\n"
            o << entry_lambdas(e) << ",\n"
            o << "                          &#{e[:dispatcher]}, #{e[:selector]})\n"
            o << "{\n}\n\n"
            o << "#{e[:ret]} Wrapper_#{e[:object]}::operator()(#{params}) const\n"
            o << "{\n"
            if e[:ret] == "void"
                o << "    #{e[:impl]}(#{callargs});\n"
            else
                o << "    return #{e[:impl]}(#{callargs});\n"
            end
            o << "}\n\n"
            return o
        end

        upp = e[:cc].to_s.empty? ? "UPP<Sig>" : "UPP<Sig, #{e[:cc]}>"
        o = +""
        o << "Wrapper_#{e[:object]}::Wrapper_#{e[:object]}()\n"
        o << "    : traps::GeneratedEntrypoint(\"#{e[:name]}\", \"InterfaceLib\", #{hexlit(e[:trap])},\n"
        o << entry_lambdas(e) << ")\n"
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
        out << "#include <base/traps.impl.h>\n"
        out << "#include <base/logging.h>\n"
        out << "#include <#{module_name}.h>\n\n"
        out << "namespace Executor { namespace trapentries {\n\n"
        entries.each {|e| out << e[:helper] if e[:helper] }

        defs = @upp_defs_by_module[module_name] || []
        ppc_defs = @upp_ppc_defs_by_module[module_name] || []
        checks = @upp_checks_by_module[module_name] || []

        # Per-type argument/return printers, shared by every trap and marshaller
        # in the module.
        log_types, @log_index = log_printer_types(entries, defs, ppc_defs)
        unless log_types.empty?
            log_types.each_with_index do |t, i|
                out << "static void logArg_#{i}(const void* p) { logging::logValue(*(const #{t}*)p); }\n"
            end
            entries.each do |e|
                next unless e[:kind] == :variant
                emit_log_printer_table(out, "logPrinters_#{e[:object]}", e[:arg_types] || [])
            end
            defs.each do |c|
                emit_log_printer_table(out, "logPrintersUpp_#{c[:upp_id]}", c[:args])
            end
            ppc_defs.each do |c|
                emit_log_printer_table(out, "logPrintersUppPpc_#{c[:ppc_id]}", c[:args])
            end
        end
        out << "\n"
        entries.each do |e|
            next if e[:kind] == :dispatcher
            out << gen_ppc_entry(e)
            out << gen_wrapper_methods(e)
        end
        out << "void ReferenceEntries_#{module_name}()\n{\n"
        entries.each do |e|
            out << "    (void)&#{e[:object]};\n"
        end
        out << "}\n\n"
        out << "} }\n\n"
        out << "namespace Executor {\n"
        entries.each do |e|
            if e[:kind] == :dispatcher
                out << "traps::GeneratedDispatcherTrap #{e[:object]}{#{e[:name].inspect}, #{hexlit(e[:trap])}, traps::SelectorKind::#{e[:selkind]}, #{hexlit(e[:selmask])}};\n"
            else
                out << "trapentries::Wrapper_#{e[:object]} #{e[:object]};\n"
            end
        end
        out << "}\n"

        unless defs.empty? && ppc_defs.empty? && checks.empty?
            out << "\nnamespace Executor {\n"
            checks.each do |c|
                out << "static_assert(std::is_same_v<#{upp_type(c)}, #{upp_canonical_type(c)}>,\n"
                out << "              \"UPP signature canonicalisation changed the C++ type\");\n"
            end
            out << "\n" unless checks.empty?
            defs.each {|c| out << upp_68k_definitions(c) }
            ppc_defs.each {|c| out << upp_ppc_definition(c) }
            out << "}\n"
        end
        out
    end
end
