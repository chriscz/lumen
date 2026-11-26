#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Blocks Bash commands that would put Claude's details on a commit: a
# Co-Authored-By trailer naming Claude or Anthropic, the Claude address as the
# identity, or a git command that makes commits (commit, cherry-pick, rebase,
# merge, am, revert, pull) while git's own identity is Claude. Cloud sessions
# set Claude as the global git identity, and cherry-pick and rebase take the
# committer from it. Claude Code runs this as a PreToolUse hook registered in
# .claude/settings.json, with the hook's JSON on stdin.
#
#   ruby scripts/check_claude_identity.rb < hook-input.json
#
# Options:
#   --help    print this usage
#
# Exit 2 blocks the call and shows the reason to the agent. Other tools, and
# input that is not JSON, exit 0, so a broken payload never stops work.

require 'json'
require 'open3'

module ClaudeIdentity
  CLAUDE = /noreply@anthropic\.com|@anthropic\.com/i
  COAUTHOR = /co-authored-by:[^\n]*(claude|anthropic)/i
  MAKES_COMMITS = /\bgit\b(?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*\s+(?:commit|cherry-pick|rebase|merge|am|revert|pull)\b/
  OWN_EMAIL = /-c\s+user\.email=["']?(?<email>[^\s"']+)/
  USAGE = <<~TEXT
    Usage: check_claude_identity.rb < hook-input.json
           check_claude_identity.rb --help

    PreToolUse hook. Reads the hook's JSON input (tool_name, tool_input) from
    stdin. Exits 2 with a reason on stderr when a Bash command would put
    Claude's details on a commit, else exits 0.
  TEXT
  FIX = 'Commit as the repository owner named in CLAUDE.md: run ' \
        '`git config --local user.name "<owner name>"` and `git config --local user.email "<owner email>"` first, ' \
        'or pass both with -c on the command. Never add a Co-Authored-By trailer for Claude.'

  module_function

  # The reason to block a command, or nil when it may run. ident is git's committer identity, "Name <email> time zone".
  def reason(command, ident)
    return "Blocked: the command adds a Co-Authored-By trailer for Claude. #{FIX}" if command.match?(COAUTHOR)

    email = command[OWN_EMAIL, :email]
    return "Blocked: the command sets the Claude address as the git identity. #{FIX}" if email&.match?(CLAUDE)
    return nil unless command.match?(MAKES_COMMITS) && email.nil? && ident.to_s.match?(CLAUDE)

    "Blocked: git would record this commit as made by Claude (#{ident[/\A[^>]*>/]}). #{FIX}"
  end

  # git's committer identity here, with the environment and config it would use; empty when there is none.
  def ident(dir = nil)
    opts = dir && File.directory?(dir) ? { chdir: dir } : {}
    out, _, status = Open3.capture3('git', 'var', 'GIT_COMMITTER_IDENT', **opts)
    status.success? ? out.strip : ''
  end

  def agy_payload?(payload)
    payload.key?('hookEventName') || payload.key?('toolCall') || payload.key?('conversationId')
  end

  def extract_command(payload)
    if (call = payload['toolCall']).is_a?(Hash)
      return nil unless call['name'] == 'run_command'

      args = call['args'].is_a?(Hash) ? call['args'] : {}
      (args['CommandLine'] || args['command']).to_s
    else
      return nil unless payload['tool_name'] == 'Bash'

      (payload['tool_input'] || {})['command'].to_s
    end
  end

  def main(argv, stdin, stdout: $stdout)
    if argv.include?('--help')
      stdout.puts USAGE
      return 0
    end
    payload = JSON.parse(stdin.read)
    command = extract_command(payload)
    why = command ? reason(command, ident(payload['cwd'])) : nil

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

exit ClaudeIdentity.main(ARGV, $stdin) if $PROGRAM_NAME == __FILE__
