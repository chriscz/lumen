# frozen_string_literal: true

# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative 'check_signing_secrets'

class CheckSigningSecretsTest < Minitest::Test
  def self.test(name, &block)
    define_method("test_#{name.gsub(/\s+/, '_')}", &block)
  end

  test 'flags keystore and key.properties filenames anywhere in the repo' do
    %w[
      release.jks
      android/app/upload.keystore
      secrets/lumen.p12
      cert.pfx
      signing.pk8
      android/key.properties
      key.properties
    ].each do |path|
      findings = CheckSigningSecrets.check_path(path, 'irrelevant')
      refute_empty findings, "expected #{path} to be flagged"
    end
  end

  test 'allows normal source and documentation files' do
    assert_empty CheckSigningSecrets.check_path('lib/app.dart', 'void main() {}')
    assert_empty CheckSigningSecrets.check_path('android/app/build.gradle.kts', 'val storeFile = System.getenv("LUMEN_KEYSTORE_PATH")')
    assert_empty CheckSigningSecrets.check_path('docs/releasing.md', "storePassword=example\n-----BEGIN PRIVATE KEY-----")
  end

  test 'allows self-signed test fixtures under test/' do
    fixture = "const key = '''\n-----BEGIN PRIVATE KEY-----\nMII...\n-----END PRIVATE KEY-----\n''';"
    assert_empty CheckSigningSecrets.check_path('test/bridge/self_signed_certificate.dart', fixture)
  end

  test 'flags private key blocks and hardcoded keystore passwords in non-test files' do
    pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----\n"
    refute_empty CheckSigningSecrets.check_path('android/app/secret.txt', pem)

    props = "storePassword=supersecret\nkeyPassword=supersecret\nkeyAlias=lumen\n"
    refute_empty CheckSigningSecrets.check_path('android/app/signing.properties', props)
  end

  test 'allows gradle variable/env lookups but flags hardcoded string literals in gradle' do
    gradle_var = "storePassword = releaseStorePassword\nkeyPassword = System.getenv(\"LUMEN_KEY_PASSWORD\")"
    assert_empty CheckSigningSecrets.check_path('android/app/build.gradle.kts', gradle_var)

    gradle_lit = 'storePassword = "super-secret-password"'
    refute_empty CheckSigningSecrets.check_path('android/app/build.gradle.kts', gradle_lit)
  end

  test 'cli supports --help' do
    out = StringIO.new
    err = StringIO.new
    code = CheckSigningSecrets.run(['--help'], stdout: out, stderr: err)
    assert_equal 0, code
    assert_includes out.string, 'Usage:'
  end
end
