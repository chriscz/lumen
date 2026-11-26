# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Tests for check_em_dashes.rb. Run with:
#   ruby scripts/test_check_em_dashes.rb

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'check_em_dashes'

# Minitest::Test with the `test "does something" do ... end` DSL.
class EmDashTest < Minitest::Test
  def self.test(name, &block)
    method_name = "test_#{name.gsub(/\W+/, '_')}"
    raise ArgumentError, "test #{name.inspect} is already defined in #{self}" if method_defined?(method_name)

    define_method(method_name, &block)
  end

  DASH = [0x2014].pack('U')
  ENTITY = '&' + 'mdash;'
  DECIMAL = '&#' + '8212;'
  HEX = '&#x' + '2014;'
  ESCAPE = '\\u' + '2014'
  BRACED = '\\u{' + '2014}'

  def scan(text)
    EmDash.scan(text)
  end
end

class ScanTest < EmDashTest
  test 'clean text has no findings' do
    assert_empty scan("plain - hyphen\nen dash – is fine\n")
  end

  test 'a literal em-dash is found with its line number' do
    assert_equal [[2, 'em-dash character']], scan("ok\nbad #{DASH} here\n")
  end

  test 'html entities and unicode escapes are found' do
    found = scan("a #{ENTITY} b\nc #{DECIMAL} d\ne #{HEX.upcase} f\ng #{ESCAPE}\nh #{BRACED}\n")
    assert_equal [1, 2, 3, 4, 5], found.map(&:first)
  end

  test 'binary content has no offences' do
    assert_empty EmDash.offences('image.png', "\x00#{DASH}".b)
  end

  test 'blockquote lines are skipped' do
    assert_empty scan("> quoted #{DASH} text\n  > nested #{ENTITY}\n")
  end
end

class CommandLineTest < EmDashTest
  SCRIPT = File.expand_path('check_em_dashes.rb', __dir__)

  def git(dir, *args)
    out, status = Open3.capture2e('git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def check(dir, *args)
    Open3.capture2e(RbConfig.ruby, SCRIPT, *args, chdir: dir)
  end

  def repo
    Dir.mktmpdir do |dir|
      git(dir, 'init', '-q')
      yield dir
    end
  end

  test 'staged content is checked rather than unstaged disk edits' do
    repo do |dir|
      path = File.join(dir, 'a.md')
      File.write(path, "bad #{DASH}\n")
      git(dir, 'add', 'a.md')
      File.write(path, "fixed on disk\n")
      out, status = check(dir)
      assert_equal 1, status.exitstatus
      assert_includes out, 'a.md:1: em-dash character'
    end
  end

  test 'all mode checks every tracked file' do
    repo do |dir|
      File.write(File.join(dir, 'a.md'), "clean\n")
      File.write(File.join(dir, 'b.dart'), "// #{ENTITY}\n")
      git(dir, 'add', '.')
      out, status = check(dir, '--all')
      assert_equal 1, status.exitstatus
      assert_includes out, 'b.dart:1: em-dash written as'
    end
  end
end
