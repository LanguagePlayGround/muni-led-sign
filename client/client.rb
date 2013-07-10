#!/usr/bin/ruby
# test

# Reads simple font files generated by scripts/genfont.pl, and renders text.
class SimpleFont
  def initialize(data)
    @glyphs = {}
    load_glyphs(data)
  end

  # Load more glyphs from data (as if generated by scripts/genfont.pl).
  # Supersedes previous glyphs on clash.
  def load_glyphs(data)
    lines = data.split("\n")
    # Whether we're anticipating a glyph header or a next line of the glyph.
    mode = :need_header
    # pointer to the record we currently read
    write_to = nil
    lines.each do |line|
      line.chomp!
      if (mode == :need_header) and (m = /(\d+) (\d+) (\d+)/.match(line))
        write_to = {:shift_h => m[2].to_i, :shift_v => m[3].to_i}
        @glyphs[m[1].to_i] = write_to
        mode = :need_line
      elsif mode == :need_line
        if line.empty?
          mode = :need_header
        else
          # This will write into @glyphs array as write_to references one of its
          # elements.
          write_to[:bitmap] ||= []
          write_to[:bitmap] << line.split('')
        end
      end
    end
  end

  # Render string given the max height above the baseline.  Returns rectangular
  # array, starting from top-left corner.
  # Opts: ignore_shift_h - whether to ignore shift_h read from the font.
  def render(string, height, opts = {})
    # We'll store, temporarily, bits in buf hash, where hash[[i,j]] is a bit i
    # points up, and j points right from the start of the baseline. 
    buf = {}
    width = 0
    # Technically, it should be String#split, but we don't support chars >127
    # anyway.
    string.each_byte do |c_code|
      glyph = @glyphs[c_code]
      add_shift_h = opts[:ignore_shift_h] ? 0 : glyph[:shift_h]
      glyph[:bitmap].each_with_index do |row, i|
        row.each_with_index do |bit, j|
          bit_row = (glyph[:shift_v] - 1) - i
          bit_col = width + j + add_shift_h
          buf[[bit_row, bit_col]] = bit
          #height = bit_row if height < bit_row
          raise "negative value for letter #{c_code}" if bit_row < 0
        end
        # Compute the new width.
      end
      width += (glyph[:bitmap][0] || []).length
      # Insert interval between letters.
      width += 1 + add_shift_h
    end
    # now render the final array
    result = []
    buf.each do |xy, bit|
      row = (height - 1) - xy[0]
      col = xy[1]
      result[row] ||= []
      result[row][col] = bit
    end
    # Fill nil-s with zeroes.
    result.map! do |row|
      expanded_row = row || []
      # Expand row up to width.
      if expanded_row.size < width
        expanded_row[width] = nil
        expanded_row.pop
      end
      # Replace nil-s in this row with zeroes.
      expanded_row.map{|bit| bit || 0}
    end
    return result
  end

  # Same as render, but renders several lines (it is an array), and places them
  # below each other.  Accepts the same options as "render," and also these:
  #   distance: distance between lines in pixels.
  def render_multiline(lines, line_height, opts = {})
    line_pics = lines.map {|line| render(line, line_height, opts)}
    line_pics.each {|lp| $stderr.puts lp.zero_one}
    # Compose text out of lines.  Center the lines.
    # Determine the width of the overall canvas.
    width = line_pics.map {|img| (img.first || []).length}.max
    # Create wide enough empty canvas.
    line_shift = line_height + (opts[:distance] || 1)
    canvas = (1..line_shift*lines.length).map do |_|
      (1..width).map{|_| 0}
    end
    # Put each line onto the canvas.
    line_pics.each_with_index do |line_pic, line_i|
      line_pic.each_with_index do |row, i|
        h_shift = (width - row.length) / 2
        row.each_with_index do |bit, j|
          canvas[line_i*line_shift + i][h_shift + j] = bit
        end
      end
    end
    canvas
  end
end

class Array
  def zero_one
    map{|row| row.join('')}.join("\n")
  end
end

# Load generated font.
sf = SimpleFont.new(IO.read('client/font/7x7.simpleglyphs'))
# Load amendments to the letters I don't like.
sf.load_glyphs(IO.read('client/font/amends.simpleglyphs'))
# Load local, application-specific glyphs
sf.load_glyphs(IO.read('client/font/specific.simpleglyphs'))

require 'optparse'

require 'muni'
require_relative 'lib/enhanced_open3'

options = {
  :bad_timing => 13,
}
OptionParser.new do |opts|
  opts.banner = "Usage: client.rb --route F --direction inbound --stop 'Ferry Building'"

  opts.on('--route [ROUTE]', "Route to get predictions for") {|v| options[:route] = v}
  opts.on('--direction [inbound/outbound]', "Route direction") {|v| options[:direction] = v}
  opts.on('--stop [STOP_NAME]', "Stop to watch") {|v| options[:stop] = v}
  opts.on('--timing MINUTES', Integer, "Warn if distance is longer than this.") {|v| options[:bad_timing] = v}
end.parse!

def text(data)
  draw = ['/usr/bin/perl', 'client/lowlevel.pl', '--type=text']
  print = proc {|line| $stderr.puts line}
  EnhancedOpen3.open3_input_linewise(data, print, print, *draw)
end

def pic(data)
  draw = ['/usr/bin/perl', 'client/lowlevel.pl', '--type=pic']
  print = proc {|line| $stderr.puts line}
  EnhancedOpen3.open3_input_linewise(data, print, print, *draw)
end

# Returns array of predictions for this route, direction, and stop in UTC times.
# in_out is 'inbound' for inbound routes, or 'outbound'
def get_arrival_times(route, stop, in_out)
  raise unless route and stop and in_out
  route_handler = Muni::Route.find(route)
  stop_handler = route_handler.send(in_out.to_sym).stop_at(stop)
  raise "Couldn't find stop: found '#{stop_handler.title}' for '#{stop}'" if
      stop != stop_handler.title
  return stop_handler.predictions.map(&:time)
end

# Returns hash of predictions for this stop in UTC times for all routes.  Keys
# are route names, and values are arrays of predictions for that route at this
# stop.
def get_stop_arrivals(stopId)
  raise unless stopId
  stop = Muni::Stop.new({ :stopId => stopId })
  return stop.predictions_for_all_routes
end

# Convert from Nextbus format to what it actually displayed on a minu sign.
def fixup_route_name(route_name, prediction)
  # For now, just truncate, except for one thing.
  if route_name.start_with? 'KT'
    if prediction.dirTag == 'KT__OB1'
      'K-Ingleside'
    else
      'T-Third Street'
    end
  else
    route_name
  end
end

if options[:route] != 'all'
  arrival_times = get_arrival_times(options[:route], options[:stop], options[:direction])

  # Render these times
  puts arrival_times.inspect
  predictions = arrival_times.map{|t| ((t - Time.now)/60).floor}

  predictions_str = ''
  prev = 0

  for t in predictions do
    # 31 is a specific charater defined in specific.simpleglyphs
    predictions_str << "#{((t-prev) >= options[:bad_timing])? 128.chr : '-'}#{t}"
    prev = t
  end

  pic(sf.render("#{options[:route]}#{predictions_str}", 8, :ignore_shift_h => true).zero_one)
else
  arrival_times = get_stop_arrivals(options[:stop])
  $stderr.puts arrival_times.inspect
  texts_for_sign = []
  arrival_times_text = arrival_times.each do |route, predictions|
    # Show first two predictions
    prediction_text = predictions.slice(0,2).map(&:muni_time).join(' & ')
    unless prediction_text.empty?
      # Fixup route name.
      route_name = fixup_route_name(route, predictions[0])
      texts_for_sign << sf.render_multiline([route_name, prediction_text], 8, :ignore_shift_h => true, :distance => 0)
    end
  end
  text_for_sign = texts_for_sign.map(&:zero_one).join("\n\n")
  pic(text_for_sign)
end

