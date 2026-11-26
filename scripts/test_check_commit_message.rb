# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Tests for check_commit_message.rb. Run with:
#   ruby scripts/test_check_commit_message.rb

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tempfile'
require_relative 'check_commit_message'

# Minitest::Test with the `test "does something" do ... end` DSL.
class CommitTest < Minitest::Test
  TRAILERS = "\n\nAssisted-by-AI-model: claude-opus-5-5\nAssisted-by-AI-harness: claude-code-web\n"

  def self.test(name, &block)
    method_name = "test_#{name.gsub(/\W+/, '_')}"
    raise ArgumentError, "test #{name.inspect} is already defined in #{self}" if method_defined?(method_name)

    define_method(method_name, &block)
  end

  def offences(message)
    CommitMessage.offences(message)
  end

  def with_trailers(subject, body = nil)
    [subject, body].compact.join("\n\n") + TRAILERS
  end
end

class SubjectTest < CommitTest
  test 'a conventional subject with trailers passes' do
    assert_empty offences(with_trailers('feat(x-plan-event-model): add skill'))
  end

  test 'every allowed type passes' do
    %w[feat fix docs test chore refactor build ci perf style revert].each do |type|
      assert_empty offences(with_trailers("#{type}: do the thing")), type
    end
  end

  test 'a scope is optional and a breaking change marker is allowed' do
    assert_empty offences(with_trailers('fix: handle missing when'))
    assert_empty offences(with_trailers('feat(em)!: drop the self-test'))
  end

  test 'an unknown type is an offence' do
    assert_match(/type/, offences(with_trailers('feature: add skill')).join)
  end

  test 'a subject without the colon and space is an offence' do
    refute_empty offences(with_trailers('feat add skill'))
    refute_empty offences(with_trailers('feat:add skill'))
  end

  test 'a scope must be kebab-case' do
    refute_empty offences(with_trailers('feat(X Plan): add skill'))
    refute_empty offences(with_trailers('feat(x_plan): add skill'))
  end

  test 'the description must start lowercase and not end with a period' do
    assert_match(/lowercase/, offences(with_trailers('feat: Add skill')).join)
    assert_match(/period/, offences(with_trailers('feat: add skill.')).join)
  end

  test 'the subject may not exceed 72 characters' do
    long = "feat: #{'a' * 70}"
    assert_match(/72/, offences(with_trailers(long)).join)
  end

  test 'merge, revert, fixup and squash subjects are accepted as git writes them' do
    assert_empty offences("Merge branch 'main' into feat/x#{TRAILERS}")
    assert_empty offences("Revert \"feat: add skill\"#{TRAILERS}")
    assert_empty offences("fixup! feat: add skill#{TRAILERS}")
    assert_empty offences("squash! feat: add skill#{TRAILERS}")
  end
end

class BodyAndTrailersTest < CommitTest
  test 'a body must be separated from the subject by a blank line' do
    message = "feat: add skill\nmore detail here#{TRAILERS}"
    assert_match(/blank line/, offences(message).join)
  end

  test 'both assisted-by trailers are required' do
    only_model = "feat: add skill\n\nAssisted-by-AI-model: claude-opus-5-5\n"
    assert_match(/Assisted-by-AI-harness/, offences(only_model).join)
    none = "feat: add skill\n"
    result = offences(none).join
    assert_match(/Assisted-by-AI-model/, result)
    assert_match(/Assisted-by-AI-harness/, result)
  end

  test 'trailer values must be kebab-case' do
    good = "feat: add skill\n\nAssisted-by-AI-model: claude-fable-5-1\nAssisted-by-AI-harness: claude-code-web\n"
    assert_empty offences(good)
    bad_model = "feat: add skill\n\nAssisted-by-AI-model: Claude Opus 5.5\nAssisted-by-AI-harness: claude-code\n"
    assert_match(/Assisted-by-AI-model.*kebab-case/, offences(bad_model).join)
    bad_harness = "feat: add skill\n\nAssisted-by-AI-model: claude-opus-5-5\nAssisted-by-AI-harness: claude_code_web\n"
    assert_match(/Assisted-by-AI-harness.*kebab-case/, offences(bad_harness).join)
  end

  test 'a trailer with an empty value is reported as missing' do
    message = "feat: add skill\n\nAssisted-by-AI-model: \nAssisted-by-AI-harness: claude-code\n"
    assert_match(/Assisted-by-AI-model/, offences(message).join)
  end

  test 'a co-authored-by trailer naming claude or anthropic is an offence' do
    message = "feat: add skill#{TRAILERS}Co-Authored-By: Claude Opus <noreply@anthropic.com>\n"
    assert_match(/Co-Authored-By/, offences(message).join)
    human = "feat: add skill#{TRAILERS}Co-Authored-By: Sam Lee <sam@example.com>\n"
    assert_empty offences(human)
  end

  test 'comment lines and the scissors section are ignored' do
    message = "feat: add skill#{TRAILERS}# Please enter the commit message\n# ------------------------ >8 ------------------------\ndiff --git a b\n"
    assert_empty offences(message)
  end

  test 'an empty message is an offence' do
    refute_empty offences("\n# only comments\n")
  end

  test 'an em-dash anywhere in the message is an offence' do
    assert_match(/em-dash/, offences(with_trailers("feat: add skill", "one thing #{[0x2014].pack('U')} another")).join)
  end
end

class CLITest < CommitTest
  SCRIPT = File.expand_path('check_commit_message.rb', __dir__)

  def run_cli(message)
    Tempfile.create('COMMIT_EDITMSG') do |f|
      f.write(message)
      f.flush
      Open3.capture3(RbConfig.ruby, SCRIPT, f.path)
    end
  end

  test 'exits 0 silently for a good message file' do
    out, err, status = run_cli(with_trailers('docs: add CLAUDE.md'))
    assert_equal 0, status.exitstatus
    assert_empty out
    assert_empty err
  end

  test 'exits 1 and explains for a bad message file' do
    out, _err, status = run_cli("Add CLAUDE.md\n")
    assert_equal 1, status.exitstatus
    assert_match(/type\(scope\): description/, out)
    assert_match(/Assisted-by-AI-model/, out)
  end

  test 'exits 2 without a file argument' do
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT)
    assert_equal 2, status.exitstatus
    assert_match(/usage/i, err)
  end

  test 'requiring the script prints nothing and does not run the CLI' do
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', "require #{SCRIPT.inspect}")
    assert_equal 0, status.exitstatus
    assert_empty out
    assert_empty err
  end
end
