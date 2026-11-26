#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Checks a commit message against the rules in CLAUDE.md.
#
#   ruby scripts/check_commit_message.rb .git/COMMIT_EDITMSG
#
# Rules:
# - Subject is a Conventional Commit: type(scope)!: description, with an
#   allowed type, a kebab-case scope, a lowercase description, no trailing
#   period, and at most 72 characters. Merge, Revert, fixup! and squash!
#   subjects are accepted as git writes them.
# - A body is separated from the subject by a blank line.
# - The trailers Assisted-by-AI-model and Assisted-by-AI-harness are present
#   and their values are kebab-case (claude-opus-5-5, claude-code-web).
# - No Co-Authored-By trailer names Claude, Anthropic or an AI model.
# - No em-dash anywhere.
# Comment lines and everything after the scissors line are ignored.

module CommitMessage
  TYPES = %w[feat fix docs test chore refactor build ci perf style revert].freeze
  SUBJECT = /\A(?<type>[a-z]+)(\((?<scope>[^)]*)\))?(?<bang>!)?: (?<description>.+)\z/
  SCOPE = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
  GIT_GENERATED = /\A(Merge |Revert "|fixup! |squash! )/
  SCISSORS = /\A# -+ >8 -+\z/
  REQUIRED_TRAILERS = %w[Assisted-by-AI-model Assisted-by-AI-harness].freeze
  AI_COAUTHOR = /\ACo-Authored-By:.*(claude|anthropic|gpt|gemini|copilot|codex)/i
  MAX_SUBJECT = 72
  KEBAB = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
  EM_DASH = [0x2014].pack('U')

  module_function

  # Lines git will keep: everything before the scissors, minus comments.
  def effective_lines(message)
    lines = []
    message.each_line(chomp: true) do |line|
      break if line.match?(SCISSORS)
      next if line.start_with?('#')

      lines << line
    end
    lines.shift while lines.first&.strip&.empty?
    lines.pop while lines.last&.strip&.empty?
    lines
  end

  def offences(message)
    lines = effective_lines(message)
    return ['the commit message is empty'] if lines.empty?

    found = []
    found << 'the message contains an em-dash; write "-" or rephrase' if lines.join("\n").include?(EM_DASH)
    found.concat(subject_offences(lines.first))
    found << 'the body must be separated from the subject by a blank line' if lines[1] && !lines[1].strip.empty?
    found.concat(trailer_offences(lines))
    found
  end

  def subject_offences(subject)
    return [] if subject.match?(GIT_GENERATED)

    found = []
    found << "the subject is #{subject.length} characters; keep it within #{MAX_SUBJECT}" if subject.length > MAX_SUBJECT
    m = subject.match(SUBJECT)
    return found << "the subject must read type(scope): description, for example feat(x-plan-event-model): add skill (got #{subject.inspect})" unless m

    found << "unknown type #{m[:type].inspect}; use one of #{TYPES.join(', ')}" unless TYPES.include?(m[:type])
    found << "the scope #{m[:scope].inspect} must be kebab-case" if m[:scope] && !m[:scope].match?(SCOPE)
    found << 'the description must start lowercase' unless m[:description].match?(/\A[a-z0-9]/)
    found << 'the description must not end with a period' if m[:description].end_with?('.')
    found
  end

  def trailer_offences(lines)
    found = []
    REQUIRED_TRAILERS.each do |name|
      line = lines.find { |l| l.start_with?("#{name}:") }
      value = line&.delete_prefix("#{name}:")&.strip
      if value.nil? || value.empty?
        found << "missing trailer #{name}: <value> at the end of the message"
      elsif !value.match?(KEBAB)
        found << "trailer #{name}: #{value.inspect} must be kebab-case, for example claude-opus-5-5 or claude-code-web"
      end
    end
    lines.each do |line|
      found << "#{line.strip}: never attribute an AI as Co-Authored-By; use the Assisted-by trailers instead" if line.match?(AI_COAUTHOR)
    end
    found
  end

  def run(argv)
    path = argv.first
    unless path && File.file?(path)
      warn 'usage: ruby scripts/check_commit_message.rb <commit message file>'
      return 2
    end
    found = offences(File.read(path, encoding: 'UTF-8'))
    return 0 if found.empty?

    found.each_with_index { |message, i| puts "#{i + 1}. #{message}" }
    puts 'See the Commits section of CLAUDE.md.'
    1
  end
end

exit CommitMessage.run(ARGV) if $PROGRAM_NAME == __FILE__
