#!/usr/bin/env ruby
#
# Check defs/DragMgr.yaml against Apple's Drag.h.
#
# The Drag Manager's 68K interface is one trap, _DragDispatch (0xABED), with a
# routine selector in D0.  Those selector numbers appear in no Apple
# documentation: they exist only in the TWOWORDINLINE sequences in the header,
# so DragMgr.yaml transcribes them, and a transcribed number that is wrong is
# not a compile error -- it is a call to the wrong routine on a live trap.
# This is what makes that transcription checkable rather than trusted.
#
#   ruby tests/dragmgr_selectors.rb [path/to/Drag.h]
#   APPLE_DRAG_H=/path/to/Drag.h ruby tests/dragmgr_selectors.rb
#
# Apple's header is not redistributable and is not in this repository, so
# without it this SKIPS rather than fails: a check nobody can run is worse
# than one that says it did not run.  Where the header is present it compares
# name, selector, return type and argument count, and exits non-zero on any
# disagreement.

require 'yaml'

ROOT = File.expand_path('..', __dir__)
DEFS = File.join(ROOT, 'defs', 'DragMgr.yaml')

header = ARGV[0] || ENV['APPLE_DRAG_H']
if header.nil? || !File.exist?(header)
  puts "dragmgr_selectors: SKIP (Apple's Drag.h not given; " \
       "pass a path or set APPLE_DRAG_H)"
  exit 0
end

# ---- ours, out of the definitions the generator reads ----

ours = {}
YAML.load_file(DEFS).each do |entry|
  fun = entry['function']
  next unless fun && fun['selector']
  args = fun['args'] || []
  # YAML resolves `0x000E` to the integer 14 on its own.  Parsing that as hex
  # a second time yields 20, and the first nine selectors are unchanged by the
  # mistake, so a check that stopped early would have passed.
  sel = fun['selector']
  sel = sel.is_a?(Integer) ? sel : Integer(sel.to_s, 16)
  ours[fun['name']] = {
    selector: sel & 0xFF,
    ret: (fun['return'] || 'void').to_s.strip,
    argc: args.length
  }
end

# ---- Apple's, out of the inline sequences ----
#
#   EXTERN_API( OSErr )
#   InstallTrackingHandler  (DragTrackingHandlerUPP trackingHandler,
#                            ...)                   TWOWORDINLINE(0x7001, 0xABED);
#
# Only the trap's own functions are wanted: the header also declares UPP glue
# and Carbon-era calls that are not dispatched through 0xABED.

apple = {}
text = File.read(header, encoding: 'BINARY').force_encoding('UTF-8')
text.scan(/EXTERN_API\(\s*([\w\s\*]+?)\s*\)\s*\n(\w+)\s*\((.*?)\)\s*
           TWOWORDINLINE\(0x([0-9A-Fa-f]{4}),\s*0xABED\)/mx) do |ret, name, args, sel|
  argc = args.strip == 'void' ? 0 : args.split(/,(?![^()]*\))/).length
  apple[name] = { selector: Integer(sel, 16) & 0xFF, ret: ret.strip, argc: argc }
end

if apple.empty?
  warn "dragmgr_selectors: FAIL -- no TWOWORDINLINE(.., 0xABED) in #{header}; " \
       'is that Apple\'s Drag.h?'
  exit 1
end

# ---- compare ----

problems = []
(apple.keys - ours.keys).sort.each { |n| problems << "#{n}: in Apple's header, not in DragMgr.yaml" }
(ours.keys - apple.keys).sort.each { |n| problems << "#{n}: in DragMgr.yaml, not in Apple's header" }

(apple.keys & ours.keys).sort.each do |name|
  a = apple[name]
  o = ours[name]
  if a[:selector] != o[:selector]
    problems << format("%s: selector 0x%02X here, 0x%02X in Apple's header",
                       name, o[:selector], a[:selector])
  end
  problems << "#{name}: returns #{o[:ret]} here, #{a[:ret]} in Apple's header" if a[:ret] != o[:ret]
  if a[:argc] != o[:argc]
    problems << "#{name}: #{o[:argc]} arguments here, #{a[:argc]} in Apple's header"
  end
end

if problems.empty?
  used = ours.values.map { |v| v[:selector] }.sort
  gaps = (used.first..used.last).reject { |v| used.include?(v) }
  puts format('dragmgr_selectors: OK -- %d functions, name, selector, return ' \
              'type and argument count all agree with %s',
              ours.length, File.basename(header))
  puts format('dragmgr_selectors: selectors 0x%02X..0x%02X%s',
              used.first, used.last,
              gaps.empty? ? '' : ", absent: #{gaps.map { |g| format('0x%02X', g) }.join(', ')}" \
                                 " (Apple's numbering, not a gap here)")
  exit 0
end

warn "dragmgr_selectors: FAIL -- #{problems.length} disagreement(s)"
problems.each { |p| warn "  #{p}" }
exit 1
