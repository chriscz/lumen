#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Pure-Ruby release helper for GitHub Actions and local releases.
#
#   ruby scripts/prepare_release.rb --version 0.2.0 [--date YYYY-MM-DD] [--dry-run] [--debug]
#   ruby scripts/prepare_release.rb --check-version 0.2.0
#   ruby scripts/prepare_release.rb --read-version-code
#   ruby scripts/prepare_release.rb --extract-notes 0.2.0 [--out release-notes.md]
#
# Updates pubspec.yaml (version + incrementing build number), rolls
# CHANGELOG.md (Keep a Changelog format), writes F-Droid Fastlane release
# notes (fastlane/metadata/android/en-US/changelogs/<versionCode>.txt),
# verifies tag consistency, and extracts release notes for `gh release create`.
# Uses Ruby 3 stdlib only.

require 'date'
require 'fileutils'
require 'optparse'

module PrepareRelease
  SEMVER = /\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/
  PUBSPEC_VERSION = /^version:\s*([^\s+#]+)(?:\+(\d+))?\s*$/
  REPO_SLUG = 'chriscz/lumen'
  FASTLANE_MAX_CHARS = 500
  FASTLANE_CHANGELOG_DIR = 'fastlane/metadata/android/en-US/changelogs'

  module_function

  def valid_version?(version)
    !version.nil? && version.match?(SEMVER)
  end

  def read_pubspec_version(pubspec_text)
    m = pubspec_text.match(PUBSPEC_VERSION)
    raise 'Could not find version: line in pubspec.yaml' unless m

    [m[1], m[2]&.to_i]
  end

  def bump_pubspec(pubspec_text, new_version)
    old_ver, old_build = read_pubspec_version(pubspec_text)
    return pubspec_text if old_ver == new_version

    next_build = (old_build || 0) + 1
    pubspec_text.sub(PUBSPEC_VERSION, "version: #{new_version}+#{next_build}")
  end

  def extract_notes(changelog_text, version)
    escaped = Regexp.escape(version)
    lines = changelog_text.lines
    start_idx = lines.index { |l| l.match?(/\A## \[#{escaped}\](?:\s+-.*)?\s*\z/) }
    return nil unless start_idx

    body = []
    ((start_idx + 1)...lines.length).each do |i|
      line = lines[i]
      break if line.start_with?('## [') || line.match?(/\A\[[^\]]+\]:\s+https?:\/\//)

      body << line
    end
    text = body.join.strip
    text.empty? ? nil : "#{text}\n"
  end

  def format_fastlane_changelog(notes_text)
    return '' if notes_text.nil? || notes_text.strip.empty?

    cleaned = notes_text.lines.map do |line|
      l = line.rstrip
      if l.match?(/\A#+\s+/)
        next nil
      end

      l.gsub(/\*\*([^*]+)\*\*/, '\1')
       .gsub(/`([^`]+)`/, '\1')
       .gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
    end.compact.join("\n").gsub(/\n{3,}/, "\n\n").strip

    return "#{cleaned}\n" if cleaned.length + 1 <= FASTLANE_MAX_CHARS

    truncated = cleaned[0, FASTLANE_MAX_CHARS - 5].rstrip
    "#{truncated}...\n"
  end

  def roll_changelog(changelog_text, new_version, date_str: Date.today.iso8601, repo_slug: REPO_SLUG)
    return changelog_text if extract_notes(changelog_text, new_version)

    escaped = Regexp.escape(new_version)
    raise 'CHANGELOG.md is missing "## [Unreleased]" heading' unless changelog_text.include?('## [Unreleased]')

    prev_match = changelog_text.match(/^## \[(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\]/)
    prev_version = prev_match ? prev_match[1] : nil

    updated = changelog_text.sub(
      /^## \[Unreleased\]\s*$/,
      "## [Unreleased]\n\n## [#{new_version}] - #{date_str}"
    )

    unreleased_link = "[Unreleased]: https://github.com/#{repo_slug}/compare/v#{new_version}...HEAD"
    version_link = if prev_version
                     "[#{new_version}]: https://github.com/#{repo_slug}/compare/v#{prev_version}...v#{new_version}"
                   else
                     "[#{new_version}]: https://github.com/#{repo_slug}/releases/tag/v#{new_version}"
                   end

    if updated.match?(/^\[Unreleased\]:\s+https?:\/\/.*$/)
      updated = updated.sub(/^\[Unreleased\]:\s+https?:\/\/.*$/, "#{unreleased_link}\n#{version_link}")
    elsif !updated.match?(/^\[#{escaped}\]:/)
      updated = "#{updated.rstrip}\n\n#{unreleased_link}\n#{version_link}\n"
    end

    updated
  end

  def run(argv, stdout: $stdout, stderr: $stderr)
    opts = {
      root: Dir.pwd,
      date: Date.today.iso8601,
      dry_run: false,
      debug: false,
      out: nil
    }
    mode = nil
    version = nil

    parser = OptionParser.new do |o|
      o.banner = 'Usage: ruby scripts/prepare_release.rb [options]'
      o.on('--version VER', 'Prepare pubspec.yaml, CHANGELOG.md, and Fastlane notes for VER (X.Y.Z)') do |v|
        mode = :prepare
        version = v.delete_prefix('v')
      end
      o.on('--check-version VER', 'Verify pubspec.yaml matches VER (exit 1 on mismatch)') do |v|
        mode = :check
        version = v.delete_prefix('v')
      end
      o.on('--read-version-code', 'Print integer Android versionCode (+N) from pubspec.yaml') do
        mode = :version_code
      end
      o.on('--extract-notes VER', 'Print CHANGELOG.md notes for VER (or write to --out)') do |v|
        mode = :extract
        version = v.delete_prefix('v')
      end
      o.on('--out FILE', 'Output path for --extract-notes') { |v| opts[:out] = v }
      o.on('--date YYYY-MM-DD', 'Release date for CHANGELOG.md (default: today)') { |v| opts[:date] = v }
      o.on('--root DIR', 'Repository root (default: current directory)') { |v| opts[:root] = v }
      o.on('--dry-run', 'Show planned file updates without writing') { opts[:dry_run] = true }
      o.on('--debug', 'Print actions to stderr prefixed with + ') { opts[:debug] = true }
      o.on('-h', '--help', 'Show this help') do
        stdout.puts o
        return 0
      end
    end

    parser.parse!(argv)
    if mode.nil? || (mode != :version_code && !valid_version?(version))
      stderr.puts "Invalid or missing semantic version: #{version.inspect}"
      stderr.puts parser
      return 2
    end

    pubspec_path = File.join(opts[:root], 'pubspec.yaml')
    pubspec_text = File.read(pubspec_path, encoding: 'UTF-8')

    if mode == :version_code
      _, build_num = read_pubspec_version(pubspec_text)
      raise 'pubspec.yaml version is missing +<versionCode>' unless build_num

      stdout.puts build_num
      return 0
    end

    changelog_path = File.join(opts[:root], 'CHANGELOG.md')
    changelog_text = File.read(changelog_path, encoding: 'UTF-8')

    case mode
    when :check
      actual, = read_pubspec_version(pubspec_text)
      stderr.puts "+ check pubspec.yaml version (#{actual}) == #{version}" if opts[:debug]
      if actual != version
        stderr.puts "Version mismatch: pubspec.yaml has #{actual}, expected #{version}"
        return 1
      end
      stdout.puts "OK: pubspec.yaml version matches #{version}"
      0
    when :extract
      notes = extract_notes(changelog_text, version)
      stderr.puts "+ extract CHANGELOG.md section for #{version} (found=#{!notes.nil?})" if opts[:debug]
      if notes.nil?
        stderr.puts "No CHANGELOG.md entry found for #{version}"
        return 1
      end
      if opts[:out]
        File.write(opts[:out], notes)
      else
        stdout.write(notes)
      end
      0
    when :prepare
      new_pubspec = bump_pubspec(pubspec_text, version)
      new_changelog = roll_changelog(changelog_text, version, date_str: opts[:date])
      _, new_build = read_pubspec_version(new_pubspec)

      changed = []
      changed << pubspec_path if new_pubspec != pubspec_text
      changed << changelog_path if new_changelog != changelog_text

      fastlane_path = nil
      fastlane_text = nil
      fl_dir = File.join(opts[:root], FASTLANE_CHANGELOG_DIR)
      if new_build && Dir.exist?(fl_dir)
        notes = extract_notes(new_changelog, version)
        formatted = format_fastlane_changelog(notes)
        unless formatted.empty?
          fastlane_path = File.join(fl_dir, "#{new_build}.txt")
          existing = File.exist?(fastlane_path) ? File.read(fastlane_path, encoding: 'UTF-8') : nil
          if existing != formatted
            fastlane_text = formatted
            changed << fastlane_path
          end
        end
      end

      if opts[:debug] || opts[:dry_run]
        if changed.empty?
          stderr.puts "+ no changes needed for #{version}"
        else
          changed.each { |p| stderr.puts "+ update #{p} for #{version}" }
        end
      end

      unless opts[:dry_run]
        File.write(pubspec_path, new_pubspec) if new_pubspec != pubspec_text
        File.write(changelog_path, new_changelog) if new_changelog != changelog_text
        File.write(fastlane_path, fastlane_text) if fastlane_path && fastlane_text
      end

      stdout.puts(changed.empty? ? "Already prepared for #{version}" : "Prepared release #{version} (#{changed.size} files)")
      0
    end
  rescue StandardError => e
    stderr.puts "Error: #{e.message}"
    1
  end
end

exit PrepareRelease.run(ARGV) if $PROGRAM_NAME == __FILE__
