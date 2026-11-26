# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Tests for check_branch_name.rb. Run with:
#   ruby scripts/test_check_branch_name.rb

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative 'check_branch_name'

# Minitest::Test with the `test "does something" do ... end` DSL.
class BranchTest < Minitest::Test
  def self.test(name, &block)
    method_name = "test_#{name.gsub(/\W+/, '_')}"
    raise ArgumentError, "test #{name.inspect} is already defined in #{self}" if method_defined?(method_name)

    define_method(method_name, &block)
  end

  def offences(name)
    BranchName.offences(name)
  end
end

class AcceptedBranchNamesTest < BranchTest
  test 'a single kebab-case segment passes' do
    assert_empty offences('main')
    assert_empty offences('release-2026-10')
  end

  test 'slash separated kebab-case segments pass' do
    assert_empty offences('feat/x-plan-event-model')
    assert_empty offences('claude/event-model-skill-design-azwbri')
    assert_empty offences('fix/em-rb/missing-when')
  end

  test 'digits are allowed inside and at the ends of words' do
    assert_empty offences('feat/ruby-3-3-support')
  end
end

class RejectedBranchNamesTest < BranchTest
  test 'uppercase letters are an offence naming the segment' do
    result = offences('feat/AddSkill')
    assert_equal 1, result.size
    assert_match(/"AddSkill"/, result.first)
  end

  test 'underscores and spaces are an offence' do
    assert_equal 1, offences('feat/add_skill').size
    assert_equal 1, offences('feat/add skill').size
  end

  test 'double or leading or trailing hyphens are an offence' do
    assert_equal 1, offences('feat/add--skill').size
    assert_equal 1, offences('feat/-add-skill').size
    assert_equal 1, offences('feat/add-skill-').size
  end

  test 'an empty segment is an offence' do
    refute_empty offences('feat//add-skill')
    refute_empty offences('feat/')
  end

  test 'each bad segment is reported once' do
    assert_equal 2, offences('Feat/Add_Skill').size
  end

  test 'a detached head is an offence that says so' do
    assert_match(/detached/, offences('').join)
  end
end

class CLITest < BranchTest
  SCRIPT = File.expand_path('check_branch_name.rb', __dir__)

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, SCRIPT, *args)
  end

  test 'exits 0 silently for a good name given as an argument' do
    out, err, status = run_cli('feat/good-name')
    assert_equal 0, status.exitstatus
    assert_empty out
    assert_empty err
  end

  test 'exits 1 and explains for a bad name given as an argument' do
    out, _err, status = run_cli('feat/Bad_Name')
    assert_equal 1, status.exitstatus
    assert_match(/kebab-case/, out)
    assert_match(/git branch -m/, out)
  end

  test 'with no argument it checks the current git branch' do
    out, _err, status = run_cli
    current = `git branch --show-current`.strip
    assert_equal BranchName.offences(current).empty? ? 0 : 1, status.exitstatus, out
  end

  test 'requiring the script prints nothing and does not run the CLI' do
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', "require #{SCRIPT.inspect}", 'feat/Bad')
    assert_equal 0, status.exitstatus
    assert_empty out
    assert_empty err
  end
end
