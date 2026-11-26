#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Checks files for em-dashes, which CLAUDE.md forbids.
#
#   ruby scripts/check_em_dashes.rb            # staged content (pre-commit)
#   ruby scripts/check_em_dashes.rb --all      # every tracked file
#   ruby scripts/check_em_dashes.rb FILE...    # the named files
#
# Finds the em-dash character itself and the forms that render as one:
# the HTML entities (named, decimal, hex) and the \u escape used by Ruby,
# Dart, JavaScript, YAML, and JSON. Binary files (any nul byte) and Markdown
# blockquotes (leading ">") are skipped.
# Exit 1 listing path:line for each offending line, exit 0 otherwise.

require 'open3'

module EmDash
  CHARACTER = [0x2014].pack('U').b
  # Assembled from parts so this file passes its own check.
  WRITTEN_AS = Regexp.new(['&' + 'mdash;', '&#0*8212;', '&#x0*2014;', '\\\\u\\{?0*2014\\}?'].join('|'), Regexp::IGNORECASE)
  QUOTATION = /\A\s*>/

  module_function

  def scan(text)
    text.b.each_line.with_index(1).filter_map do |line, number|
      if line.match?(QUOTATION)
        nil
      elsif line.include?(CHARACTER)
        [number, 'em-dash character']
      elsif (form = line[WRITTEN_AS])
        [number, "em-dash written as #{form}"]
      end
    end
  end

  def binary?(content)
    content.b.include?("\x00")
  end

  def offences(path, content)
    return [] if binary?(content)

    scan(content).map { |number, message| "#{path}:#{number}: #{message}" }
  end

  def git_paths(*args)
    out, status = Open3.capture2('git', *args, '-z')
    raise "git #{args.join(' ')} failed" unless status.success?

    out.split("\x00")
  end

  def staged
    git_paths('diff', '--cached', '--name-only', '--diff-filter=ACMR').map do |path|
      content, = Open3.capture2('git', 'show', ":#{path}", binmode: true)
      [path, content]
    end
  end

  def from_disk(paths)
    paths.select { |path| File.file?(path) }.map { |path| [path, File.binread(path)] }
  end

  def files(argv)
    if argv == ['--all'] then from_disk(git_paths('ls-files'))
    elsif argv.empty? then staged
    else from_disk(argv)
    end
  end

  def run(argv)
    found = files(argv).flat_map { |path, content| offences(path, content) }
    return 0 if found.empty?

    found.each { |message| puts message }
    puts 'CLAUDE.md forbids em-dashes. Use " - ", a comma, a colon, or parentheses instead.'
    1
  end
end

exit EmDash.run(ARGV) if $PROGRAM_NAME == __FILE__
