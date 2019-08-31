require 'yaml'
require 'prettyprint'

data = YAML::load(File.read("out/QuickDraw.yaml"))

def first_elem(item)
    item.each { |key, value| return key, value }
end

q = PrettyPrint.new(out=STDOUT, maxwidth=9999, newline=nil)
#maxwidth=79)

if true then
data.each do |item|
    q.group do
        key, value = first_elem(item)
        case key
        when "struct"
            q.text("typedef struct #{value["name"]} {")
            q.nest(4) do
                value["members"].each do |member|
                    #q.breakable
                    q.text "\n#{' '*q.indent}"
                    q.text "#{member["type"]} #{member["name"]};"
                end
            end
            q.breakable
            q.text "} #{value["name"]};"

        when "function"
            if value["trap"] and not value["selector"] and not value["registers"] then
                q.text "pascal "
            end
            q.text (value["return"] or "void")
            q.breakable
            q.text value["name"]
        end
    end
    q.text "\n\n"
end
q.flush

end

if false then
    q.text "foo"
    q.text " "
    q.text "bar"
    q.text("(")
    q.nest(4) {
            q.group {
                q.nest(4) {
                    q.breakable(sep="")
                    q.text "quux,"
                    q.breakable
                    q.text "bar,"
                    q.breakable
                    q.text "bar,"
                    q.breakable
                    q.text "quuxbar"
                }
                q.breakable("")
                q.text(")")
            }
            q.group {
                q.breakable
                q.text("= blah blah blah blah")
            }
        }
    q.newline
    q.flush
end