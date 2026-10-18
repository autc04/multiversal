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

require_relative 'executor_types'
require_relative 'executor_calling_conventions'
require_relative 'executor_traps'
