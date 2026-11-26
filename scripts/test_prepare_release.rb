# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

require 'fileutils'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative 'prepare_release'

class PrepareReleaseTest < Minitest::Test
  def self.test(name, &block)
    define_method("test_#{name.gsub(/\s+/, '_')}", &block)
  end

  SAMPLE_PUBSPEC = <<~YAML
    name: lumen
    description: "Philips Hue light controller over Bluetooth and the Hue Bridge"
    version: 0.1.0+1
  YAML

  SAMPLE_CHANGELOG = <<~MD
    # Changelog

    ## [Unreleased]

    ### Added
    - Bluetooth and Hue Bridge light control.
    - Experimental Music sync plugin.

    [Unreleased]: https://github.com/chriscz/lumen/compare/HEAD...HEAD
  MD

  test 'reads version and build number from pubspec' do
    assert_equal ['0.1.0', 1], PrepareRelease.read_pubspec_version(SAMPLE_PUBSPEC)
  end

  test 'bumps pubspec version and increments build number' do
    updated = PrepareRelease.bump_pubspec(SAMPLE_PUBSPEC, '0.2.0')
    assert_includes updated, 'version: 0.2.0+2'
    assert_equal updated, PrepareRelease.bump_pubspec(updated, '0.2.0')
  end

  test 'rolls changelog and updates compare links for chriscz/lumen' do
    rolled = PrepareRelease.roll_changelog(SAMPLE_CHANGELOG, '0.1.0', date_str: '2026-11-26')
    assert_includes rolled, "## [Unreleased]\n\n## [0.1.0] - 2026-11-26"
    assert_includes rolled, '[Unreleased]: https://github.com/chriscz/lumen/compare/v0.1.0...HEAD'
    assert_includes rolled, '[0.1.0]: https://github.com/chriscz/lumen/releases/tag/v0.1.0'
  end

  test 'extracts release notes for a version' do
    rolled = PrepareRelease.roll_changelog(SAMPLE_CHANGELOG, '0.1.0', date_str: '2026-11-26')
    notes = PrepareRelease.extract_notes(rolled, '0.1.0')
    assert_includes notes, 'Bluetooth and Hue Bridge light control.'
    refute_includes notes, '[Unreleased]'
  end

  test 'formats fastlane changelog within 500 characters' do
    long_notes = "### Added\n" + ("- A very descriptive changelog bullet entry.\n" * 20)
    fl = PrepareRelease.format_fastlane_changelog(long_notes)
    assert fl.length <= 500, "expected <= 500 chars, got #{fl.length}"
    refute_includes fl, '###'
  end

  test 'cli prepare updates pubspec, changelog, and fastlane changelog for versionCode' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'pubspec.yaml'), SAMPLE_PUBSPEC)
      File.write(File.join(dir, 'CHANGELOG.md'), SAMPLE_CHANGELOG)
      FileUtils.mkdir_p(File.join(dir, 'fastlane/metadata/android/en-US/changelogs'))

      out = StringIO.new
      err = StringIO.new
      code = PrepareRelease.run(
        ['--version', '0.2.0', '--date', '2026-11-26', '--root', dir, '--debug'],
        stdout: out, stderr: err
      )
      assert_equal 0, code, err.string
      assert_includes File.read(File.join(dir, 'pubspec.yaml')), 'version: 0.2.0+2'
      assert_includes File.read(File.join(dir, 'CHANGELOG.md')), '## [0.2.0] - 2026-11-26'

      fl_path = File.join(dir, 'fastlane/metadata/android/en-US/changelogs/2.txt')
      assert File.exist?(fl_path), 'expected fastlane changelog 2.txt to be written'
      assert_includes File.read(fl_path), 'Bluetooth and Hue Bridge light control.'
    end
  end

  test 'cli --read-version-code prints the integer build number' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'pubspec.yaml'), SAMPLE_PUBSPEC)
      File.write(File.join(dir, 'CHANGELOG.md'), SAMPLE_CHANGELOG)

      out = StringIO.new
      err = StringIO.new
      code = PrepareRelease.run(['--read-version-code', '--root', dir], stdout: out, stderr: err)
      assert_equal 0, code, err.string
      assert_equal "1\n", out.string
    end
  end

  test 'cli --dry-run does not modify files' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'pubspec.yaml'), SAMPLE_PUBSPEC)
      File.write(File.join(dir, 'CHANGELOG.md'), SAMPLE_CHANGELOG)

      out = StringIO.new
      err = StringIO.new
      code = PrepareRelease.run(
        ['--version', '0.2.0', '--date', '2026-11-26', '--root', dir, '--dry-run'],
        stdout: out, stderr: err
      )
      assert_equal 0, code
      assert_equal SAMPLE_PUBSPEC, File.read(File.join(dir, 'pubspec.yaml'))
      assert_equal SAMPLE_CHANGELOG, File.read(File.join(dir, 'CHANGELOG.md'))
    end
  end
end
