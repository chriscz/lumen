#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Blocks tool calls that would send an email address to an outside service,
# for example in a curl User-Agent, a request header or an API query string.
# Claude Code runs it as a PreToolUse hook registered in .claude/settings.json,
# with the hook's JSON on stdin. It applies to subagents and workflows too.
#
#   ruby scripts/check_outbound_email.rb < hook-input.json
#
# Options:
#   --help    print this usage
#
# A call is outbound when it is WebFetch, WebSearch or a Firecrawl tool, or a
# Bash command that runs curl or wget or names an http or https URL. Local
# commands such as `git -c user.email=... commit` pass, and the user.email=
# setting of a git command is ignored even when the command mentions curl. Exit 2 blocks the call
# and shows the reason to the agent. Input that is not JSON exits 0, so a
# broken payload never stops work.

require 'json'

module OutboundEmail
  # The last label must be letters, so a package version such as react@18.3.1 is not an address.
  EMAIL = /[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b/
  NETWORK_TOOL = /\A(?:WebFetch|WebSearch|search_web|read_url_content|fetch_url|web_fetch|web_search|mcp__Firecrawl__.+)\z/
  SHELL_TOOL = /\A(?:Bash|run_command)\z/
  NETWORK_COMMAND = %r{\b(?:curl|wget)\b|https?://}
  # git@github.com in an SSH remote is a host login, not a person's address.
  NOT_PERSONAL = /\Agit@/
  # The author setting of a local git command stays on this machine.
  GIT_AUTHOR = /user\.email=\S+/
  USAGE = <<~TEXT
    Usage: check_outbound_email.rb < hook-input.json
           check_outbound_email.rb --help

    PreToolUse hook for Claude Code (.claude/settings.json) and Antigravity
    (.agents/hooks.json). Reads the hook's JSON input from stdin. For Claude
    Code, exits 2 with a reason on stderr when an outbound call contains an
    email address, else exits 0. For Antigravity, writes a PreToolUse decision
    JSON object to stdout and exits 0.
  TEXT

  module_function

  # The reason to block a call, or nil when it may run.
  def reason(tool, input)
    text = outbound_text(tool, input)
    return nil unless text

    address = text.gsub(GIT_AUTHOR, '').scan(EMAIL).find { |a| !a.match?(NOT_PERSONAL) }
    return nil unless address

    "Blocked: this #{tool} call would send the email address #{address} to an outside service. " \
      'Never put an email address in a User-Agent, header, URL or query. ' \
      'Use a generic client name such as "misc-ai-research/1.0" and leave out mailto or email parameters.'
  end

  def outbound_text(tool, input)
    return JSON.generate(input) if tool.to_s.match?(NETWORK_TOOL)
    return nil unless tool.to_s.match?(SHELL_TOOL)

    command = input.is_a?(Hash) ? (input['command'] || input['CommandLine']).to_s : ''
    command.match?(NETWORK_COMMAND) ? command : nil
  end

  def agy_payload?(payload)
    payload.key?('hookEventName') || payload.key?('toolCall') || payload.key?('conversationId')
  end

  def extract_call(payload)
    if (call = payload['toolCall']).is_a?(Hash)
      [call['name'], call['args'] || {}]
    else
      [payload['tool_name'], payload['tool_input'] || {}]
    end
  end

  def main(argv, stdin, stdout: $stdout)
    if argv.include?('--help')
      stdout.puts USAGE
      return 0
    end
    payload = JSON.parse(stdin.read)
    tool, input = extract_call(payload)
    why = reason(tool, input)

    if agy_payload?(payload)
      response = why ? { 'decision' => 'deny', 'reason' => why } : { 'decision' => 'allow' }
      stdout.puts JSON.generate(response)
      return 0
    end
    return 0 unless why

    warn why
    2
  rescue JSON::ParserError
    0
  end
end

exit OutboundEmail.main(ARGV, $stdin) if $PROGRAM_NAME == __FILE__
