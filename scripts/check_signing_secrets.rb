#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

# Blocks accidental commits of Android signing keystores, key.properties,
# private keys, or hardcoded keystore credentials.
#
#   ruby scripts/check_signing_secrets.rb         # check staged files
#   ruby scripts/check_signing_secrets.rb --all   # check all tracked files
#   ruby scripts/check_signing_secrets.rb --debug # print underlying git commands

require 'open3'
require 'optparse'

module CheckSigningSecrets
  FORBIDDEN_FILENAME = /(?:^|\/)(?:key\.properties|[^\/]+\.(?:jks|keystore|p12|pfx|pk8))\z/i
  PRIVATE_KEY_HEADER = /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/
  GRADLE_PATH = /\.gradle(?:\.kts)?\z/i
  GRADLE_LITERAL_SECRET = /^\s*(?:storePassword|keyPassword)\s*=\s*["'][^"']+["']/
  CREDENTIAL_PROP = /^\s*(?:storePassword|keyPassword)\s*=\s*(?!\s*$)(?!\s*(?:System\.getenv|providers\.environmentVariable|\$|\{))/

  CONTENT_SKIP_PATH = %r{\A(?:test/|docs/|scripts/test_)}

  module_function

  def check_path(path, content)
    findings = []
    if path.match?(FORBIDDEN_FILENAME)
      findings << "#{path}: forbidden signing keystore or key.properties file"
      return findings
    end

    return findings if content.nil? || path.match?(CONTENT_SKIP_PATH)

    if content.match?(PRIVATE_KEY_HEADER)
      findings << "#{path}: contains a PEM private key block"
    end

    if path.match?(GRADLE_PATH)
      if content.match?(GRADLE_LITERAL_SECRET)
        findings << "#{path}: contains a hardcoded keystore password literal"
      end
    elsif content.match?(CREDENTIAL_PROP)
      findings << "#{path}: contains a hardcoded keystore password property"
    end

    findings
  end

  def git_capture(args, debug: false, stderr: $stderr)
    stderr.puts "+ git #{args.join(' ')}" if debug
    out, err, status = Open3.capture3('git', *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def staged_paths(debug: false, stderr: $stderr)
    out = git_capture(%w[diff --cached --name-only --diff-filter=ACMR -z], debug: debug, stderr: stderr)
    out.split("\0").reject(&:empty?)
  end

  def tracked_paths(debug: false, stderr: $stderr)
    out = git_capture(%w[ls-files -z], debug: debug, stderr: stderr)
    out.split("\0").reject(&:empty?)
  end

  def read_staged(path, debug: false, stderr: $stderr)
    git_capture(['show', ":#{path}"], debug: debug, stderr: stderr)
  rescue StandardError
    nil
  end

  def read_tracked(path)
    return nil unless File.file?(path)

    File.binread(path).force_encoding('UTF-8')
  rescue StandardError
    nil
  end

  def run(argv, stdout: $stdout, stderr: $stderr)
    opts = { all: false, debug: false }
    parser = OptionParser.new do |o|
      o.banner = 'Usage: ruby scripts/check_signing_secrets.rb [--all] [--debug]'
      o.on('--all', 'Check every tracked file instead of only staged files') { opts[:all] = true }
      o.on('--debug', 'Print underlying commands to stderr prefixed with + ') { opts[:debug] = true }
      o.on('-h', '--help', 'Show this help') do
        stdout.puts o
        return 0
      end
    end
    parser.parse!(argv)

    paths = opts[:all] ? tracked_paths(debug: opts[:debug], stderr: stderr) : staged_paths(debug: opts[:debug], stderr: stderr)
    findings = []
    paths.each do |path|
      content = opts[:all] ? read_tracked(path) : read_staged(path, debug: opts[:debug], stderr: stderr)
      next if content && !content.valid_encoding? && !path.match?(FORBIDDEN_FILENAME)

      findings.concat(check_path(path, content))
    end

    return 0 if findings.empty?

    stderr.puts 'Signing secret check failed:'
    findings.each { |f| stderr.puts "  - #{f}" }
    stderr.puts 'Never commit Android keystores, key.properties, or private keys.'
    1
  rescue StandardError => e
    stderr.puts "Error: #{e.message}"
    1
  end
end

exit CheckSigningSecrets.run(ARGV) if $PROGRAM_NAME == __FILE__
