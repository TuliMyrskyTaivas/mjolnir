#!/usr/bin/env ruby

# In Norse mythology, Mjölnir is the hammer of Thor, the Norse god associated with thunder.
# Mjölnir is depicted in Norse mythology as one of the most fearsome and powerful weapons
# in existence, capable of leveling mountains.
#
# But as for our worldly things, this is a tool to evaluate the performance of GoogleTests.
# It parses the gtest's output, sorts the tests by the execution time and produce the report 
# It can also save the logs of failed or "ok" (or both) tests in the separate file.
#
# Compare mode allows to find out the performance gain against another perf report. 

# Call with -h/--help to get usage example

require 'logger'
require 'optparse'
require 'fileutils'

# ===================================================================
# The structure to save the testcase metadata
# ===================================================================
class TestCase
  include Comparable

  attr_accessor :perfDiff
  attr_accessor :perfReason
  attr_accessor :elapsedTime
  attr_accessor :result
  attr_accessor :lines
  attr_reader :name

  # Constructor: testcase name is required
  def initialize(name)
    @name = name
    @lines = []
  end

  # Save the log lines of the current testcase to the separate file
  def save(out_dir)
    # Output filename is the name of the test with dot and slash
    # are replaced by underscore character
    filename = File.join(out_dir, @name.tr('/.', '_')) + '.txt'
    File.open(filename, 'w') do |f|
      f.puts(@lines)
    end

    @lines.clear
  end

  def <=>(other)
    elapsedTime <=> other.elapsedTime
  end
end

# ===================================================================
# Performance report
# ===================================================================
class Report
  attr_reader :tests

  # Constructor. Expects logger on initialization
  def initialize(logger)
    @tests = []
    @log = logger
  end

  # Convert number of milliseconds to the string representation of time duration
  def self.get_duration(milliseconds)
    hours, milliseconds   = milliseconds.divmod(1000 * 60 * 60)
    minutes, milliseconds = milliseconds.divmod(1000 * 60)
    seconds, milliseconds = milliseconds.divmod(1000)  
    '%02d:%02d:%02d.%03d' % [hours, minutes, seconds, milliseconds]
  rescue => err
    err.to_s
  end

  # Convert duration from string representation to the number of milliseconds
  def self.ms_from_string(string)
    parse_result = string.match(/^(\d{2}):(\d{2}):(\d{2}).(\d{3})$/)
    raise "invalid timestamp: \"#{string}\"" unless parse_result

    hours, minutes, seconds, milliseconds = parse_result.captures
    hours.to_i * 1000 * 3600 + minutes.to_i * 1000 * 60 + seconds.to_i * 1000 + milliseconds.to_i
  end

  # Produce the perf report from the specified log file
  def produce(logfile, options)
    @log.info("Analyzing the file #{logfile}")

    @tests = []
    current_case = nil

    File.foreach(logfile).with_index do |line, line_index|
      # Bypass some lines
      next if line.start_with?('[==========]')
      next if line.empty?

      # Check for gtest markers
      if line.start_with?('[ RUN      ]', '[       OK ]', '[  FAILED  ]', '[----------]')
        # Extract the name of marker
        what = line.strip!.slice!(0, 13).tr('[ ]', '')
        # Perform processing
        case what
        when 'RUN'
          current_case = TestCase.new(line)
        when 'OK', 'FAILED'
          parse_result = line.match(/^(.+?) \((\d+) ms\)$/)
          raise "failed to parse line #{line_index}: \"#{line}\"" unless parse_result
          raise 'format error: OK/FAILED before RUN' unless current_case

          case_name, case_time = parse_result.captures
          current_case.result = what
          current_case.elapsedTime = case_time.to_i

          if (what == 'OK' && options[:save_ok]) || (what == 'FAILED' && options[:save_failed])
            # Save should be called before adding the testcase to the list to avoid copying
            # of possibly long list of lines
            current_case.save(options[:output_dir])
          end

          @log.debug("Testcase #{current_case.name} #{current_case.result} in #{current_case.elapsedTime}ms ")
          @tests.push(current_case)
        when '----------'
          # Ignore the GTests statistics at the end of file
          break if line == 'Global test environment tear-down'
        else
          @log.error("Unrecognized pattern: #{what}")
        end

        next
      end

      # Bypass the lines outside of testcases
      next unless current_case

      # Save the log lines of testcase if required
      if options[:save_ok] || options[:save_failed]
        current_case.lines.push(line.strip!)
      end
    end

    # Calculate some statistics
    total_ms = @tests.sum(&:elapsedTime)
    failed = @tests.count { |test| test.result == 'FAILED'}
    succeeded = @tests.length - failed
    success_rate = (succeeded.to_f / @tests.length.to_f) * 100

    # Print statistics
    @log.info("#{@tests.size} tests have taken #{Report.get_duration(total_ms)}")
    @log.info("Succeeded: #{succeeded}, failed: #{failed}, success rate: #{success_rate.round(2)}%")

    # Print TOP-20 longest tests in the descending order
    @log.info('Top-10 are:')
    @tests.sort_by!(&:elapsedTime).reverse!
    @tests.first(10).each do |test|
      @log.info("#{Report.get_duration(test.elapsedTime)} - #{test.name}")
    end

    # Save statistics in the output directory
    report_file = File.join(options[:output_dir], 'perf_report.txt')
    File.open(report_file, 'w') do |f|
      f.puts('# ---------------------------------------------------------')
      f.puts("# file: #{logfile}")
      f.puts("# #{@tests.size} tests have taken #{Report.get_duration(total_ms)}")
      f.puts("# Succeeded: #{succeeded}, failed: #{failed}, success rate: #{success_rate.round(2)}%")
      f.puts('# ---------------------------------------------------------')
      @tests.each do |test|
        f.puts("#{Report.get_duration(test.elapsedTime)}\t#{test.result}\t#{test.name}")
      end
    end
  end

  # Load the perf report for the further analysis
  def load(report_file)
    File.foreach(report_file) do |line|
      # Bypass comments
      next if line.start_with?('#')

      time, result, name = line.chomp!.split(/\t/)
      test = TestCase.new(name)
      test.result = result
      test.elapsedTime = Report.ms_from_string(time)

      tests.push(test)
    end

    @log.info("#{tests.length} tests are loaded from #{report_file}")
  end

  # Compare this perf report against another one
  def compare(other, options)
    report_file = File.join(options[:output_dir], 'perf_diff.txt')

    @tests.each do |test|
      other_test = other.tests.select { |t| t.name == test.name }
      other_test = other_test.first if other_test

      unless other_test
        @log.warn("The test #{test.name} is not found in the compared report, skipping")
        next
      end

      this_time = test.elapsedTime.to_f
      other_time = other_test.elapsedTime.to_f
      test.perfDiff = ((this_time - other_time)/ other_time * 100)
      if test.result != other_test.result
        test.perfReason = "#{test.result}->#{other_test.result}"
      else
        test.perfReason = " " * 10
      end
    end

    total_duration = tests.sum(&:elapsedTime).to_f
    other_total_duration = other.tests.sum(&:elapsedTime).to_f
    total_diff = (total_duration - other_total_duration) / other_total_duration * 100
    @log.info("Total diff is #{total_diff.round(2)}%, report is written to #{report_file}")

    File.open(report_file, 'w') do |f|
      f.puts('# ---------------------------------------------------------')
      f.puts("# Total diff is #{total_diff.round(2)}%")
      f.puts('# ---------------------------------------------------------')
      @tests.sort_by!(&:perfDiff).each do |test|
        f.puts("#{test.perfDiff.round(2)}%\t#{test.perfReason}\t#{test.name}")
      end
    end
  end

  # Arrange testset to fit in the required time range
  def arrange(options)
    time_limit = options[:arrange].to_i
    @log.info("Arranging the testset to be fit into #{time_limit}ms limit")

    report_file = File.join(options[:output_dir], "perf_arrange_#{time_limit}ms.txt")
    File.open(report_file, 'w') do |f|
      current_time = 0
      total_tests = 0

      # Select tests with minimum running time first
      tests.sort_by!(&:elapsedTime)
      tests.each do |test|
        current_time += test.elapsedTime.to_i
        break if current_time > time_limit

        f.puts(test.name)
        total_tests += 1
      end
      @log.info("#{total_tests} are selected, report is written to #{report_file}")
    end
  end
end

# Parse command line
options = { output_dir: Dir.pwd }
OptionParser.new do |opts|
  opts.banner = "Usage:\n\tmjölnir.rb [-s category] [-o outdir] [-v] gtest_log.txt\n\tmjölnir.rb [-v] [-c] gtest_log1.txt gtest_log2.txt\n\tmjölnir.rb [-v] [-a] HH:MM:SS gtest_log.txt"
  opts.separator ''
  opts.separator 'Analyze mode options (report is saved in perf_report.txt):'

  opts.on('-s', '--save category', 'save logs for the test of selected category, which may be: ok, failed, all') do |c|
    case c
    when 'ok'
      options[:save_ok] = true
    when 'failed'
      options[:save_failed] = true
    when 'both'
      options[:save_ok] = true
      options[:save_failed] = true  
    else
      raise "unknown category \"%s\"" % c
    end
  end

  opts.on('-o', '--output outputDir', 'the directory to save the reports and logs (will be created if not exists') do |dir|
    FileUtils.mkdir_p(dir)
    options[:output_dir] = dir
  end

  opts.separator 'Compare mode options (report is saved in perf_diff.txt):'
  opts.on('-c', '--compare', 'compare two draupnir\'s reports') do
    options[:compare] = true
  end

  opts.separator 'Arrange mode options (report is saved to perf_arrange.txt):'
  opts.on('-a', '--arrange INTERVAL', 'arrange the testset to be accomplished in specified time range') do |a|
    options[:arrange] = Report.ms_from_string(a)
  end

  opts.separator 'Common options:'
  opts.on_tail('-v', '--verbose', 'produce verbose output') do |v|
    options[:verbose] = v
  end

  opts.on_tail('-h', '--help', 'prints this message') do
    puts opts
    exit
  end
end.parse!

# Configure the logging facilities
log = Logger.new(STDOUT, datetime_format: '%Y-%m-%d %H:%M')
log.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
log.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime} #{severity} #{msg}\n"
end

# Start processing
begin
  report = Report.new(log)

  # Select mode of operation
  if options[:compare]
    report.load(ARGV[0])

    second_report = Report.new(log)
    second_report.load(ARGV[1])

    report.compare(second_report, options)
  elsif options[:arrange]
    report.load(ARGV[0])
    report.arrange(options)
  else
    report.produce(ARGV[0], options)
  end

rescue => err
  log.fatal(err.cause)
  log.fatal(err.backtrace_locations)
end
