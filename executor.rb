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

        # Emitted typedef definitions, used to canonicalise signature spellings.
        @typedef_emitted = {}
        # Candidates seen while generating one header.
        @upp_pending = []
        # Canonical key => representative candidate, and per-module work lists.
        @upp_reps = {}
        @upp_defs_by_module = {}
        @upp_checks_by_module = {}
        # The PPC marshaller is keyed on the signature alone, so it needs its own
        # representative and per-module definition list.
        @upp_ppc_reps = {}
        @upp_ppc_defs_by_module = {}
        @upp_next_id = 0
        @upp_next_ppc_id = 0
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

        # A raw 68K entry: the implementation is a hand-written callconv::Raw
        # function RAW_<name>, and the wrapper object is stub_<name>.  Only the
        # prototype is generated; nothing is said about <name> itself.
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
                register_upp_candidate((fun["return"] or "void"), arg_types,
                                       funptr_cc(fun), conv: funptr_conv(fun))
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

    def log_desc_args(e)
        return "nullptr, nullptr, 0" if (e[:arg_types] || []).empty?
        "logPrinters_#{e[:object]}, lgvals, #{e[:arg_types].size}"
    end

    def log_values(e, names)
        return "" if (e[:arg_types] || []).empty?
        "        const void* lgvals[] = { #{names.map {|n| "&#{n}" }.join(", ")} };\n"
    end

    def logging_call(e, names)
        "    logging::LogNestingScope logScope;\n" \
        "    if(logScope.active)\n" \
        "    {\n" \
        "#{log_values(e, names)}" \
        "        logging::logTrapCallData(\"#{e[:name]}\", #{log_desc_args(e)});\n" \
        "    }\n"
    end

    def logging_return(e, names)
        o = +""
        o << "    if(logScope.active)\n"
        o << "    {\n"
        o << log_values(e, names)
        if e[:ret] == "void"
            o << "        logging::logTrapVoidReturnData(\"#{e[:name]}\", #{log_desc_args(e)});\n"
        else
            o << "        logging::logTrapValReturnData(\"#{e[:name]}\", "
            o << "logArg_#{@log_index[log_type_key(e[:ret])]}, &ret, #{log_desc_args(e)});\n"
        end
        o << "    }\n"
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
        o << logging_call(e, names)
        if e[:ret] == "void"
            o << "    #{e[:impl]}(#{callargs});\n"
        else
            o << "    #{e[:ret]} ret = #{e[:impl]}(#{callargs});\n"
        end
        o << logging_return(e, names)
        o << "    callfromPPC::ParameterPasser{cpu, nullptr}.set(ret);\n" unless e[:ret] == "void"
        o << "    cpu.r[1] = EM_A7;\n"
        o << "    return saveLR;\n"
        o << "}\n\n"
        o
    end

    def entry_cc_type(e)
        e[:cc].to_s.empty? ? "callconv::Pascal" : e[:cc]
    end

    # The two non-capturing entry lambdas passed to GeneratedEntrypoint.  They
    # name the trap implementation so its type is checked against the
    # signature's marshaller, with no erased implementation pointer.
    def entry_lambdas(e)
        cc = entry_cc_type(e)
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
                next if (e[:arg_types] || []).empty?
                out << "static const logging::LogArgFn logPrinters_#{e[:object]}[] = { "
                out << e[:arg_types].map {|t| "logArg_#{@log_index[log_type_key(t)]}" }.join(", ")
                out << " };\n"
            end
            defs.each do |c|
                next if c[:args].empty?
                out << "static const logging::LogArgFn logPrintersUpp_#{c[:upp_id]}[] = { "
                out << c[:args].map {|t| "logArg_#{@log_index[log_type_key(t)]}" }.join(", ")
                out << " };\n"
            end
            ppc_defs.each do |c|
                next if c[:args].empty?
                out << "static const logging::LogArgFn logPrintersUppPpc_#{c[:ppc_id]}[] = { "
                out << c[:args].map {|t| "logArg_#{@log_index[log_type_key(t)]}" }.join(", ")
                out << " };\n"
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

    # Record the emitted definition so that signature canonicalisation can
    # resolve typedefs exactly the way the generated header does.
    def declare_typedef(value)
        t1, pre, post = guestify_type(value["type"], @need_guest)
        @typedef_emitted[value["name"]] = "#{t1}#{pre}#{post}".strip
        super
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

        register_upp_candidate((value["return"] or "void"),
                               args.map {|arg| decl(arg["type"], "").strip},
                               funptr_cc(value), conv: funptr_conv(value))
    end

    def declare_verbatim(value)
        @out << "BEGIN_EXECUTOR_ONLY\n"
        @out << value.strip << "\n"
        @out << "END_EXECUTOR_ONLY\n"
    end

    def remap_name(name)
        name == "MacTypes" ? "ExMacTypes" : name
    end

    # ---- UPP marshalling -------------------------------------------------
    #
    # One `invokeUPP` / `createCallbackUPP` per distinct C++ signature.  The
    # key is the emitted C++ type, not the YAML spelling: typedefs are
    # transparent, so LONGINT/int32_t, MenuRef/MenuHandle, DialogPtr/WindowPtr
    # and friends collapse.  The definitions are emitted once, in the module
    # that first declares the signature; every other module that mentions it
    # gets declarations (repeating a declaration is harmless).

    def register_upp_candidate(ret, arg_types, cc, conv: nil)
        @upp_pending << { ret: ret, args: arg_types, cc: cc, conv: conv }
    end

    # The register/extras part of a funptr or executor_marshaling declaration,
    # or nil for Pascal/CCall.  The 68K marshaller body is generated from it.
    def funptr_conv(value)
        args = (value["args"] or [])
        if value["returnreg"] || value["executor_extras"] || args.any? {|arg| arg["register"]}
            conv = regcall_conv(value)
            { ret: conv[:ret], args: conv[:args],
              extras: (conv[:extras] || "").split(",").map(&:strip).reject(&:empty?) }
        else
            nil
        end
    end

    def funptr_cc(value)
        args = (value["args"] or [])
        if value["returnreg"] || value["executor_extras"] || args.any? {|arg| arg["register"]}
            register_cc(regcall_conv(value))
        elsif value["callconv"] == "C"
            "callconv::CCall"
        else
            ""
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

    def upp_key(c)
        [canon_type(c[:ret]),
         c[:args].map {|a| canon_type(a, param: true)},
         canon_cc(c[:cc])].join(" | ")
    end

    def upp_sig(c)
        "#{c[:ret]}(#{c[:args].join(', ')})"
    end

    # The PPC marshaller is keyed on the signature alone; the 68K calling
    # convention (register/extras descriptors) does not exist on PowerPC.
    def upp_ppc_key(c)
        [canon_type(c[:ret]),
         c[:args].map {|a| canon_type(a, param: true) }].join(" | ")
    end

    def upp_cc_type(c)
        c[:cc].to_s.empty? ? "callconv::Pascal" : c[:cc]
    end

    def upp_type(c)
        cc = c[:cc].to_s.empty? ? "" : ", #{c[:cc]}"
        "UPP<#{upp_sig(c)}#{cc}>"
    end

    # The same type written from the canonical spelling.  Used to check that a
    # spelling was merged (or kept apart) for the right reason: it is emitted in
    # the spelling's own module, so every name in it is in scope.
    def upp_canonical_type(c)
        cc = c[:cc].to_s.empty? ? "" : ", #{c[:cc]}"
        sig = "#{canon_type(c[:ret])}(#{c[:args].map {|a| canon_type(a, param: true)}.join(', ')})"
        "UPP<#{sig}#{cc}>"
    end

    def upp_params(c)
        c[:args].each_with_index.map {|t, i| "#{t} a#{i}" }.join(", ")
    end

    def upp_argnames(c)
        c[:args].each_with_index.map {|t, i| "a#{i}" }.join(", ")
    end

    def upp_arglist(c)
        c[:args].each_index.map {|i| "a#{i}" }
    end

    def upp_is_ccall?(c)
        canon_cc(c[:cc]) == "CCall"
    end

    # ---- marshaller bodies ---------------------------------------------

    def upp_printer_name(id_key, c)
        id_key == :ppc_id ? "trapentries::logPrintersUppPpc_#{c[:ppc_id]}" : "trapentries::logPrintersUpp_#{c[:upp_id]}"
    end

    def upp_log_values(args)
        return "" if args.empty?
        "        const void* lgvals[] = { #{args.map {|a| "&#{a}" }.join(", ")} };\n"
    end

    def upp_log_call(c, args, id_key)
        o = +""
        o << "    logging::LogNestingScope logScope;\n"
        o << "    if(logScope.active)\n"
        o << "    {\n"
        o << upp_log_values(args)
        if args.empty?
            o << "        logging::logTrapCallData(ep->name, nullptr, nullptr, 0);\n"
        else
            o << "        logging::logTrapCallData(ep->name, #{upp_printer_name(id_key, c)}, lgvals, #{args.size});\n"
        end
        o << "    }\n"
        o
    end

    def upp_log_return(c, args, id_key)
        if args.empty?
            values = "nullptr, nullptr, 0"
        else
            values = "#{upp_printer_name(id_key, c)}, lgvals, #{args.size}"
        end
        o = +""
        o << "    if(logScope.active)\n"
        o << "    {\n"
        o << upp_log_values(args)
        if c[:ret] == "void"
            o << "        logging::logTrapVoidReturnData(ep->name, #{values});\n"
        else
            o << "        logging::logTrapValReturnData(ep->name, trapentries::logArg_#{@log_index[log_type_key(c[:ret])]}, &ret, #{values});\n"
        end
        o << "    }\n"
        o
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
            o << upp_log_call(c, names, :upp_id)
            if ret == "void"
                o << "    f(#{names.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{names.join(', ')});\n"
            end
            o << upp_log_return(c, names, :upp_id)
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
            o << upp_log_call(c, values, :upp_id)
            if ret == "void"
                o << "    f(#{values.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{values.join(', ')});\n"
            end
            o << upp_log_return(c, values, :upp_id)
            o << "    EM_D0 = ret;\n" unless ret == "void"
            o << "    return callconv::stack::pop<syn68k_addr_t>();\n"
        else
            o << "    syn68k_addr_t retaddr = callconv::stack::pop<syn68k_addr_t>();\n"
            args.each_with_index.to_a.reverse_each do |t, i|
                o << "    std::decay_t<#{t}> #{names[i]} = callconv::stack::pop<std::decay_t<#{t}>>();\n"
            end
            o << upp_log_call(c, names, :upp_id)
            if ret == "void"
                o << "    f(#{names.join(', ')});\n"
            else
                o << "    #{ret} ret = f(#{names.join(', ')});\n"
            end
            o << upp_log_return(c, names, :upp_id)
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
        o << upp_log_call(c, names, :ppc_id)
        if ret == "void"
            o << "    f(#{names.join(', ')});\n"
        else
            o << "    #{ret} ret = f(#{names.join(', ')});\n"
        end
        o << upp_log_return(c, names, :ppc_id)
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

        @out << "\n\n"

        @out << "namespace Executor {\n\n"
    end

    def generate_postamble(header)
        @entries.each do |e|
            next unless [:pascal, :register, :sub, :notrap].include?(e[:kind])
            conv = nil
            if e[:kind] == :register
                conv = { ret: e[:retconv], args: e[:argconvs], extras: e[:extras] }
            end
            register_upp_candidate(e[:ret], e[:arg_types], e[:cc], conv: conv)
        end

        module_name = remap_name(header.name)
        local_reps = {}
        @upp_pending.each do |c|
            key = upp_key(c)
            next if local_reps.key?(key)
            local_reps[key] = c
            (@upp_checks_by_module[module_name] ||= []) << c

            if !@upp_reps.key?(key)
                c[:upp_id] = (@upp_next_id += 1)
                @upp_reps[key] = c
                (@upp_defs_by_module[module_name] ||= []) << c
            end

            ppc_key = upp_ppc_key(c)
            if !@upp_ppc_reps.key?(ppc_key)
                c[:ppc_id] = (@upp_next_ppc_id += 1)
                @upp_ppc_reps[ppc_key] = c
                (@upp_ppc_defs_by_module[module_name] ||= []) << c
            end
        end
        @upp_pending = []

        @out << "\n// UPP marshalling (definitions in trap_entries/)\n"
        @out << upp_declarations(local_reps)
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
        generated = []
        # Pass 1: generate every header so that the per-module marshaller
        # definition lists are complete before any definition is written.
        # before any definition is written.
        defs.topsort.each do |name|
            name2 = remap_name(name)
            moduleList << name2
            header_text = generate_header(defs.headers[name])
            generated << [defs.headers[name], name2, header_text, @entries_for_header]
        end
        # Pass 2: write the files.
        generated.each do |header, name2, header_text, entries|
            formatted_file "#{$options.output_dir}/api/#{name2}.h" do |f|
                f << header_text
            end
            formatted_file "#{$options.output_dir}/structdump/#{name2}.cpp" do |f|
                f << generate_structdump(header, name2, best)
            end
            formatted_file "#{$options.output_dir}/trap_entries/#{name2}.cpp" do |f|
                f << generate_trap_entries(name2, entries)
            end
            entryModules << name2
        end
        formatted_file "#{$options.output_dir}/trap_entries/ReferenceAllEntries.cpp" do |f|
            f << "// Generated by make-multiverse.rb - DO NOT EDIT\n"
            f << "namespace Executor { namespace trapentries {\n"
            entryModules.each { |m| f << "void ReferenceEntries_#{m}();\n" }
            f << "\nvoid ReferenceAllEntries() {\n"
            entryModules.each { |m| f << "    ReferenceEntries_#{m}();\n" }
            f << "}\n}}\n"
        end
        formatted_file "#{$options.output_dir}/structdump/ReferenceAllStructDumps.cpp" do |f|
            f << generate_reference_all_struct_dumps(moduleList)
        end
        print "Done.\n"
    end
end
