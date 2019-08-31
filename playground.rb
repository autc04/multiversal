require 'yaml'

data = YAML::load(File.read("out/QuickDraw.yaml"))

def first_elem(item)
    item.each { |key, value| return key, value }
end

def out(str)
    print str
    print " "
end

def box(str)
    maxlinelen = str.lines.map{|s| s.length}.max
    
    print "/#{'*'*77}\n"
    #print " *#{' '*75}*\n"

    str.each_line do |s|
        c = (75 - s.length)
        b = c/2
        a = c-b
        print " *#{' '*a}#{s}#{' '*b}*\n"
    end

    print " #{'*'*77}/\n"
    
end

def decl(type, thing)
    type =~ /(const +)?([A-Za-z0-9_]+) *((\* *)*)(.*)/
    return "#{$1}#{$2} #{$3}#{thing}#{$5}"
end

data.each do |item|
    key, value = first_elem(item)

    box(value["name"]) if value["name"]

    case key
    when "struct"
        out "typedef struct #{value["name"]} {"
        value["members"].each do |member|
            out decl(member["type"], member["name"])
            out ";"
        end
        out "} #{value["name"]};"

    when "typedef"
        out "typedef "
        out decl(value["type"], value["name"])
        out ";"


    when "function"
        if value["trap"] and not value["selector"] and not value["registers"] then
            out "pascal"
        end
        out (value["return"] or "void")
        out value["name"]
        out "("
        first = true
        value["args"] and value["args"].each do |arg|
            out "," unless first
            first = false

            if arg["name"] then
                out decl(arg["type"], arg["name"])
            else
                out arg["type"]
            end
        end
        out ");\n"
    end

    print "\n\n"
end
