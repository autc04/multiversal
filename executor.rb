require './generator'

class ExecutorGenerator < Generator
    def decl(type, thing)
        if thing then
            type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
            return "#{$1}#{$2} #{$3}#{thing}#{$5}"
        else
            return type
        end
    end

    def declare_struct_union(what, value)
        @out << "#{what} #{value["name"]};"
                
        if value["members"] then
            @out << "#{what} #{value["name"]} {"
            @out << "GUEST_STRUCT;"
            declare_members(value["members"])
            @out << "};"
        end
    end
    def declare_dispatcher(value)
    end
    def declare_lowmem(value)
    end

    def declare_function(value)
    end

    def declare_funptr(value)
    end


    def generate(defs)
        FileUtils.mkdir_p "out/executor"
        defs.headers.each do |name, header|
            formatted_file "out/executor/#{name}.h" do |f|
                f << generate_header(header)
            end
        end
    end
end