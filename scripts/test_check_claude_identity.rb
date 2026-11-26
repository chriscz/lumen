# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Tests for check_claude_identity.rb. Run with:
#   ruby scripts/test_check_claude_identity.rb

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'check_claude_identity'

# Minitest::Test with the `test "does something" do ... end` DSL.
class ClaudeIdentityTest < Minitest::Test
  def self.test(name, &block)
    method_name = "test_#{name.gsub(/\W+/, '_')}"
    raise ArgumentError, "test #{name.inspect} is already defined in #{self}" if method_defined?(method_name)

    define_method(method_name, &block)
  end

  CLAUDE = 'Claude <noreply@anthropic.com> 1700000000 +0000'
  OWNER = 'Owner Person <owner@example.org> 1700000000 +0000'

  def reason(command, ident = OWNER)
    ClaudeIdentity.reason(command, ident)
  end

  def run_hook(payload, dir)
    script = File.join(__dir__, 'check_claude_identity.rb')
    Open3.capture3(RbConfig.ruby, script, stdin_data: JSON.generate(payload), chdir: dir)
  end

  def repo(name, email)
    dir = Dir.mktmpdir
    system('git', 'init', '-q', dir, exception: true)
    system('git', '-C', dir, 'config', 'user.name', name, exception: true)
    system('git', '-C', dir, 'config', 'user.email', email, exception: true)
    dir
  end
end

class TrailerTest < ClaudeIdentityTest
  test 'a commit message with a Claude co-author trailer is blocked' do
    refute_nil reason("git commit -m 'fix: x\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>'")
  end

  test 'a co-author trailer naming Anthropic in any case is blocked' do
    refute_nil reason("git commit -F - <<'EOF'\nfix: x\n\nco-authored-by: Anthropic bot <bot@anthropic.com>\nEOF")
  end

  test 'a command that sets the Claude address as the identity is blocked' do
    refute_nil reason('git -c user.email=noreply@anthropic.com commit -m x')
  end

  test 'a commit message with only the Assisted-by trailers passes' do
    assert_nil reason("git commit -m 'fix: x\n\nAssisted-by-AI-model: claude-opus-5-5\nAssisted-by-AI-harness: claude-code-web'")
  end
end

class IdentityTest < ClaudeIdentityTest
  test 'commands that make commits are blocked while git would commit as Claude' do
    %w[commit cherry-pick rebase merge am revert pull].each do |sub|
      refute_nil reason("git #{sub} x", CLAUDE), sub
    end
  end

  test 'a git option before the subcommand does not hide it' do
    refute_nil reason('cd repo && git -C repo rebase origin/main', CLAUDE)
  end

  test 'a command that sets another user.email passes even while the default is Claude' do
    assert_nil reason('git -c user.name="Owner" -c user.email=owner@example.org commit -m x', CLAUDE)
  end

  test 'commands that make no commits pass while the default is Claude' do
    ['git status', 'git log --oneline', 'git push origin main', 'git fetch origin', 'echo commit'].each do |cmd|
      assert_nil reason(cmd, CLAUDE), cmd
    end
  end

  test 'commands that make commits pass when git commits as the owner' do
    assert_nil reason('git rebase origin/main')
  end
end

class HookTest < ClaudeIdentityTest
  test 'blocks a commit in a repository whose identity is Claude, with exit 2 and the fix' do
    out, err, status = run_hook({ 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'git commit -m x' } },
                                repo('Claude', 'noreply@anthropic.com'))
    assert_equal 2, status.exitstatus
    assert_empty out
    assert_match(/git config --local user\.name/, err)
  end

  test 'lets a commit through in a repository with the owner identity' do
    _, _, status = run_hook({ 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'git commit -m x' } },
                            repo('Owner Person', 'owner@example.org'))
    assert_equal 0, status.exitstatus
  end

  test 'ignores other tools and input that is not JSON' do
    dir = repo('Claude', 'noreply@anthropic.com')
    assert_equal 0, run_hook({ 'tool_name' => 'Read', 'tool_input' => { 'file_path' => 'x' } }, dir)[2].exitstatus
    script = File.join(__dir__, 'check_claude_identity.rb')
    assert_equal 0, Open3.capture3(RbConfig.ruby, script, stdin_data: 'not json', chdir: dir)[2].exitstatus
  end

  test '--help prints usage' do
    out, _, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'check_claude_identity.rb'), '--help')
    assert_equal 0, status.exitstatus
    assert_match(/Usage/, out)
  end

  test 'agy PreToolUse payload denies a Claude commit with JSON on stdout and allows an owner commit' do
    claude_dir = repo('Claude', 'noreply@anthropic.com')
    payload = {
      'hookEventName' => 'PreToolUse',
      'cwd' => claude_dir,
      'toolCall' => { 'name' => 'run_command', 'args' => { 'CommandLine' => 'git commit -m x' } }
    }
    out, err, status = run_hook(payload, __dir__)
    assert_equal 0, status.exitstatus, err
    result = JSON.parse(out)
    assert_equal 'deny', result['decision']
    assert_match(/git config --local user\.name/, result['reason'])

    owner_dir = repo('Owner Person', 'owner@example.org')
    out, err, status = run_hook(payload.merge('cwd' => owner_dir), __dir__)
    assert_equal 0, status.exitstatus, err
    assert_equal({ 'decision' => 'allow' }, JSON.parse(out))
  end
end
