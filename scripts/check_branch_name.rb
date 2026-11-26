#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Checks that a git branch name is kebab-case.
#
#   ruby scripts/check_branch_name.rb [BRANCH]
#
# With no argument it checks the current branch. Every slash-separated
# segment must be lowercase letters and digits, words joined by single
# hyphens: feat/x-plan-event-model, fix/em-rb/missing-when, main.
# Exit 1 with the offending segments, exit 0 otherwise.

module BranchName
  KEBAB = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  module_function

  def offences(name)
    return ['no branch is checked out (detached HEAD); create a kebab-case branch first'] if name.to_s.strip.empty?

    name.split('/', -1).filter_map do |segment|
      next if segment.match?(KEBAB)

      "branch #{name.inspect}: segment #{segment.inspect} is not kebab-case"
    end
  end

  def current_branch
    `git branch --show-current`.strip
  end

  def run(argv)
    name = argv.first || current_branch
    found = offences(name)
    return 0 if found.empty?

    found.each { |message| puts message }
    puts 'Branch names are kebab-case segments separated by slashes (CLAUDE.md). Rename with: git branch -m <new-name>'
    1
  end
end

exit BranchName.run(ARGV) if $PROGRAM_NAME == __FILE__
