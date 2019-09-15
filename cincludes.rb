require './generator'

class CIncludesGenerator < Generator
    def encode_size(type)
        sz = size_of_type(type)
        return 4 unless sz
        return sz >= 4 ? 3 : sz
    end
    
    def decl(type, thing)
        if thing then
            type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
            return "#{$1}#{$2} #{$3}#{thing}#{$5}"
        else
            return type
        end
    end

    def declare_trapnum(name, trapno)
        @out << "enum { _#{name} = #{hexlit(trapno)} };\n"
    end

    def declare_inline(name, rettype, args, expr)
        @out << "#define #{name}(#{args.map {|x|x["name"]}.compact.join(", ")}) (#{expr})\n"
    end

    def generate_function_definition(out:, fun:, name:, args:, m68kinlines:)
        return if not m68kinlines
        writeback = ""
        out << "pascal " << (fun["return"] or "void") << " " << name <<
            "(" << args.map {|x| decl(x["type"],x["name"])}.join(", ") << ")"
        out << "{"

        clobbers = Set.new(["%d0","%d1","%d2","%a0","%a1"])
        inputs = []
        outputs = []
        if fun["returnreg"] then
            register = "%" + fun["returnreg"].downcase
            out << "register #{fun["return"]} _retval __asm__(\"#{register}\");"
            
            clobbers.delete?(register)
            outputs << "\"=r\"(_retval)"
        end

        args.each do |arg|
            if arg["register"] =~ /(Out|InOut)<([AD][0-7])>/ then
                io = $1
                register = "%" + $2.downcase
                if arg["type"] =~ /(.*)\*/ then
                    type = $1
                    out << "register #{type} _#{arg["name"]} __asm__(\"#{register}\");"
                    out << "_#{arg["name"]} = *#{arg["name"]};" if io == "InOut"
                    writeback << "*#{arg["name"]} = _#{arg["name"]};"

                    clobbers.delete?(register)
                    outputs << "\"=r\"(_#{arg["name"]})"
                    inputs << "\"r\"(_#{arg["name"]})" if io == "InOut"
                end
            elsif arg["register"] =~ /[AD][0-7]/ then
                register = "%" + arg["register"].downcase
                out << "register #{arg["type"]} _#{arg["name"]} __asm__(\"#{register}\");"
                out << "_#{arg["name"]} = #{arg["name"]};"

                clobbers.delete?(register)
                inputs << "\"r\"(_#{arg["name"]})"
            end
        end
        
        out << "\n// clang-format off\n"
        out << "    __asm__ volatile(\".short #{m68kinlines.join(", ")}\"\n"
        out << " " * 8 << ": #{outputs.join(", ")}\n"
        out << " " * 8 << ": #{inputs.join(", ")}\n"
        out << " " * 8 << ": #{clobbers.map{|x| '"'+x+'"'}.join(", ")});"
        out << "\n// clang-format on\n"
        out << writeback
        out << "return _retval;" if fun["returnreg"]
        out << "}"
    end

    def declare_function(fun, variant_index:nil)
        return if fun["name"] =~ /ROMlib/
        if fun["variants"] and not variant_index
            
            fun["variants"].each_index { |i| declare_function(fun, variant_index:i) }
            return
        end

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

        declare_trapnum(name, fun["trap"] | trapbits) if fun["trap"] and not fun["selector"]
        
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
                @out << "#if TARGET_CPU_68K\n"
                @out << "#pragma parameter "
                @out << simpleregs.shift if fun["returnreg"]
                @out << " " << name
                @out << "(" << simpleregs.join(", ") << ")" if simpleregs.length > 0
                @out << "\n"
                @out << "#endif\n"
            end
        end

        if fun["inline"] then
            declare_inline(name, (fun["return"] or "void"), args, fun["inline"])
        else
            @out << "pascal "
            @out << (fun["return"] or "void") << " "
            @out << name << "("
            @out << args.map {|arg| decl(arg["type"], arg["name"])}.join(", ")
            @out << ")"
            @out << " M68K_INLINE(" << m68kinlines.join(", ") << ")" if m68kinlines.length > 0 and not complex
            @out << ";\n"

            if complex and m68kinlines then
                generate_function_definition(out:@impl_out, fun:fun, name:name, args:args, m68kinlines:m68kinlines)
            end
        end

        if not fun["inline"] and (m68kinlines.length == 0 or complex) then
            @functions_needing_glue << name
        end
    end

    def declare_struct_union(what, value)
        @out << "typedef #{what} #{value["name"]} #{value["name"]};"
                
        if value["members"] then
            @out << "#{what} #{value["name"]} {"
            declare_members(value["members"])
            @out << "};"
        end
    end

    def declare_dispatcher(value)
        declare_trapnum(value["name"], value["trap"]) unless value["selector-location"] == "TrapBits"
    end


    def declare_funptr(value)
        @out << "typedef pascal "

        name = value["name"]
        if name=~/^([A-Za-z_][A-Za-z0-9]*)(ProcPtr|UPP)$/ then
            name = $1 
        else
            print "WARNING: strange function pointer #{name}\n"
        end
                      

        @out << (value["return"] or "void") << " "
        @out << "(*" << name << "ProcPtr" << ")("
        args = (value["args"] or [])
        @out << args.map {|arg|decl(arg["type"], arg["name"])}.join(", ")
        @out << ");\n"
        
        if args.any? {|arg| arg["register"]} then
            procinfo = 42;
            print "WARNING UNSUPPORTED register funptr: #{name}\n"
        else
            procinfo = 0;
            procinfo |= encode_size(value["return"]) << 4
            shift = 6
            args.each do |arg|
                procinfo |= encode_size(arg["type"]) << shift
                shift += 2
            end
        end
        
        @out << <<~UPPDECL
            #if TARGET_RT_MAC_CFM
            typedef UniversalProcPtr #{name}UPP;
            enum { upp#{name}ProcInfo = #{hexlit(procinfo,32)} };
        UPPDECL
        declare_inline("New#{name}UPP", "#{name}UPP", [{"name"=>"proc", "type"=>"#{name}ProcPtr"}],
            "(#{name}UPP)NewRoutineDescriptor((ProcPtr)(proc), upp#{name}ProcInfo, GetCurrentArchitecture())")
        declare_inline("Dispose#{name}UPP", nil, [{"name"=>"upp", "type"=>"#{name}UPP"}],
            "DisposeRoutineDescriptor((UniversalProcPtr)(upp))")
        @out << <<~UPPDECL
            #else

            typedef #{name}ProcPtr #{name}UPP;
            #define New#{name}UPP(proc) (proc)
            #define Dispose#{name}UPP(proc) do { } while(false)

            #endif

            #define New#{name}Proc(proc) New#{name}UPP(proc)
            #define Dispose#{name}Proc(proc) Dispose#{name}UPP(proc)

        UPPDECL
    end

    def declare_lowmem(value)
        if value["type"] =~ /^(.*)\[[^\[\]]*\]$/ then
            declare_inline("LMGet" + value["name"], $1 + "*", [], "(#{$1}*)" + hexlit(value["address"]))
        else
            expr = "*(#{value["type"]}*)" + hexlit(value["address"])
            declare_inline("LMGet" + value["name"], value["type"], [], expr)
            declare_inline("LMSet" + value["name"], "void",
                [{"type" => value["type"], "name" => "val"}], expr + " = val")
        end
    end

    def generate_preamble(header)
        super
        @out << "#pragma pack(push, 2)\n"
        @out << "\n\n"
    end

    def generate_postamble(header)
        @out << "#pragma pack(pop)\n\n\n"              
        super
    end

    def generate_comment(key, value)
        super unless key == "executor_only"
    end
    

    def generate(defs)
        @functions_needing_glue = []
        
        FileUtils.mkdir_p "out/CIncludes"
        FileUtils.mkdir_p "out/RIncludes"
        FileUtils.mkdir_p "out/src"
        FileUtils.mkdir_p "out/obj"
        FileUtils.mkdir_p "out/lib"
        
        formatted_file("out/CIncludes/Multiverse.h") do |f|
            f << <<~PREAMBLE
                #pragma once
                #include <stdint.h>
                #include <stdbool.h>
                #include <stddef.h>
                
                #ifdef __m68k__
                    #define TARGET_CPU_68K 1
                    #define TARGET_CPU_PPC 0
                    #define TARGET_RT_MAC_CFM 0
                    #define M68K_INLINE(...) = { __VA_ARGS__ }
                    #define GetCurrentArchitecture() ((int8_t)0)
                #else
                    #define TARGET_CPU_68K 0
                    #define TARGET_CPU_PPC 1
                    #define TARGET_RT_MAC_CFM 1
                    #define M68K_INLINE(...)
                    #define GetCurrentArchitecture() ((int8_t)1)
        
                    #ifndef pascal
                        #define pascal
                    #endif
                #endif
        
                #define TARGET_API_MAC_CARBON 0
        
                //typedef void (*ProcPtr)();
                typedef struct RoutineDescriptor *ProcPtr;
                #define nil NULL
        
                #define STACK_ROUTINE_PARAMETER(n, sz) ((sz) << (kStackParameterPhase + ((n)-1) * kStackParameterWidth))
            
            
            PREAMBLE
        
            defs.topsort.each do |name|
                header = defs.headers[name]
                inc = generate_header(header)
        
                f << inc
        
                if @impl_out.length > 0 then
                    formatted_file("out/src/#{header.name}.c") do |f|
                        f << "#include \"Multiverse.h\"\n"
                        f << @impl_out
                    end
                end
            end
        
            f << <<~POSTAMBLE
        
                extern QDGlobals qd;
                #define UnloadSeg(x) do {} while(false)
            POSTAMBLE
        end
        
        ["Carbon", "Devices", "Dialogs", "Errors", "Events", "Files", "FixMath",
            "Fonts", "Icons", "LowMem", "MacMemory", "MacTypes", "Memory", "Menus",
            "MixedMode", "NumberFormatting", "OSUtils", "Processes", "Quickdraw",
            "Resources", "SegLoad", "Sound", "TextEdit", "TextUtils", "ToolUtils",
            "Traps", "Windows", "ConditionalMacros", "Gestalt", "AppleEvents", 
            "StandardFile", "Serial"].each do |name|
            File.open("out/CIncludes/#{name}.h", "w") do |f|
                f << "#pragma once\n"
                f << "#include \"Multiverse.h\"\n"
            end
        end 
        
        Dir.glob("custom/*.r") {|f| FileUtils.cp(f, "out/RIncludes/")}
        Dir.glob("custom/*.c") {|f| FileUtils.cp(f, "out/src/")}
        ["CodeFragments", "Dialogs", "Finder", "Icons", "MacTypes",
         "Menus", "MixedMode", "Processes", "Windows", "ConditionalMacros"].each do |name|
            File.open("out/RIncludes/#{name}.r", "w") do |f|
                f << "#include \"Multiverse.r\"\n"
            end
        end
        
        File.open("out/CIncludes/needs-glue.txt", "w") do |f|
            @functions_needing_glue.each {|name| f << name + "\n"}
        end
        
        Dir.glob('out/src/*.c') do |file|
            name = File.basename(file, '.c')
            system("m68k-apple-macos-gcc -c #{file} -o out/obj/#{name}.o -I out/CIncludes -O -ffunction-sections")
        end
        system("m68k-apple-macos-ar cqs out/lib/libInterface.a out/obj/*.o")
    end
end
