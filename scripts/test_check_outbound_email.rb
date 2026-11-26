# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Tests for check_outbound_email.rb. Run with:
#   ruby scripts/test_check_outbound_email.rb

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative 'check_outbound_email'

# Minitest::Test with the `test "does something" do ... end` DSL.
class OutboundEmailTest < Minitest::Test
  def self.test(name, &block)
    method_name = "test_#{name.gsub(/\W+/, '_')}"
    raise ArgumentError, "test #{name.inspect} is already defined in #{self}" if method_defined?(method_name)

    define_method(method_name, &block)
  end

  def reason(tool, input)
    OutboundEmail.reason(tool, input)
  end

  def run_hook(payload)
    script = File.join(__dir__, 'check_outbound_email.rb')
    Open3.capture3(RbConfig.ruby, script, stdin_data: JSON.generate(payload))
  end
end

class BlockedTest < OutboundEmailTest
  test 'curl with an email in the user agent is blocked' do
    refute_nil reason('Bash', 'command' => 'curl -A "research/1.0 (someone@example.com)" https://upload.wikimedia.org/x.png')
  end

  test 'wget with an email in a header is blocked' do
    refute_nil reason('Bash', 'command' => 'wget --header "From: a.b+c@mail.example.org" https://example.org')
  end

  test 'an email in a query string to an API is blocked' do
    refute_nil reason('Bash', 'command' => 'curl "https://api.unpaywall.org/v2/10.1/x?email=me@example.com"')
  end

  test 'WebFetch with an email in the url is blocked' do
    refute_nil reason('WebFetch', 'url' => 'https://api.crossref.org/works?mailto=me@example.com', 'prompt' => 'x')
  end

  test 'a Firecrawl call with an email anywhere in its input is blocked' do
    refute_nil reason('mcp__Firecrawl__firecrawl_search', 'query' => 'papers by me@example.com')
  end

  test 'the reason names the address and says what to do instead' do
    text = reason('Bash', 'command' => 'curl -A "x (me@example.com)" https://example.org')
    assert_includes text, 'me@example.com'
    assert_includes text, 'generic'
  end
end

class AllowedTest < OutboundEmailTest
  test 'curl without an email passes' do
    assert_nil reason('Bash', 'command' => 'curl -sSL -A "misc-ai-research/1.0" https://example.org')
  end

  test 'the fixed client identity from CLAUDE.md passes, and the old one with an example address does not' do
    assert_nil reason('Bash', 'command' => 'curl -A "Unknown Bobtronic Research" https://www.sec.gov/x')
    refute_nil reason('Bash', 'command' => 'curl -A "Unknown Bobtronic Research bob@example.com" https://www.sec.gov/x')
  end

  test 'a git commit with an author email passes because it sends nothing' do
    assert_nil reason('Bash', 'command' => 'git -c user.email=me@example.com commit -m "x"')
  end

  test 'a git commit author email passes even when the message mentions curl and a URL' do
    command = "git -c user.email=me@example.com commit -F - <<'EOF'\nfix: stop curl User-Agent leaks, see https://example.org\nEOF"
    assert_nil reason('Bash', 'command' => command)
  end

  test 'a curl next to a git author email is still blocked when curl sends another address' do
    refute_nil reason('Bash', 'command' => 'git -c user.email=me@example.com commit -m x && curl -A "you@example.com" https://x.org')
  end

  test 'an npm package version in a CDN url is not mistaken for an email' do
    assert_nil reason('Bash', 'command' => 'curl https://unpkg.com/react@18.3.1/LICENSE https://unpkg.com/@babel/standalone@7.26.4/LICENSE')
  end

  test 'a git ssh remote is not mistaken for an email' do
    assert_nil reason('Bash', 'command' => 'curl https://example.org && git remote add o git@github.com:a/b.git')
  end

  test 'local file tools pass even with an email' do
    assert_nil reason('Write', 'file_path' => '/tmp/x', 'content' => 'curl me@example.com https://x')
  end

  test 'a Firecrawl call without an email passes' do
    assert_nil reason('mcp__Firecrawl__firecrawl_scrape', 'url' => 'https://example.org/gantt')
  end
end

class HookTest < OutboundEmailTest
  test 'a blocked call exits 2 with the reason on stderr' do
    _out, err, status = run_hook('tool_name' => 'Bash', 'tool_input' => { 'command' => 'curl -A "me@example.com" https://x.org' })
    assert_equal 2, status.exitstatus
    assert_includes err, 'me@example.com'
  end

  test 'an allowed call exits 0 and prints nothing' do
    out, err, status = run_hook('tool_name' => 'Bash', 'tool_input' => { 'command' => 'ls' })
    assert_equal 0, status.exitstatus
    assert_equal '', out + err
  end

  test 'input that is not JSON exits 0, so a broken payload never blocks work' do
    _out, _err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'check_outbound_email.rb'), stdin_data: 'nope')
    assert_equal 0, status.exitstatus
  end

  test '--help prints usage and exits 0' do
    out, _err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'check_outbound_email.rb'), '--help')
    assert_equal 0, status.exitstatus
    assert_includes out, 'Usage'
  end

  test 'agy PreToolUse payload blocks an outbound run_command email with JSON deny on stdout' do
    payload = {
      'hookEventName' => 'PreToolUse',
      'conversationId' => 'conv-1',
      'toolCall' => {
        'id' => 'toolu_1',
        'name' => 'run_command',
        'args' => { 'CommandLine' => 'curl -A "me@example.com" https://x.org' }
      }
    }
    out, err, status = run_hook(payload)
    assert_equal 0, status.exitstatus, err
    result = JSON.parse(out)
    assert_equal 'deny', result['decision']
    assert_includes result['reason'], 'me@example.com'
  end

  test 'agy PreToolUse payload blocks search_web with an email and allows clean run_command' do
    blocked = {
      'hookEventName' => 'PreToolUse',
      'toolCall' => { 'name' => 'search_web', 'args' => { 'query' => 'contact me@example.com' } }
    }
    out, _err, status = run_hook(blocked)
    assert_equal 0, status.exitstatus
    assert_equal 'deny', JSON.parse(out)['decision']

    allowed = {
      'hookEventName' => 'PreToolUse',
      'toolCall' => { 'name' => 'run_command', 'args' => { 'CommandLine' => 'curl -A "misc-ai-research/1.0" https://x.org' } }
    }
    out, _err, status = run_hook(allowed)
    assert_equal 0, status.exitstatus
    assert_equal({ 'decision' => 'allow' }, JSON.parse(out))
  end
end
