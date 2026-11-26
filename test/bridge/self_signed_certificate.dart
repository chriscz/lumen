// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';
import 'dart:io';

/// A self-signed ECDSA certificate for 127.0.0.1, valid until 2126, standing
/// in for a bridge's Signify certificate that no device trusts. Test only;
/// made with:
///
///     openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
///       -nodes -days 36500 -subj "/CN=Test bridge" \
///       -addext "subjectAltName=IP:127.0.0.1" -keyout key.pem -out cert.pem
const selfSignedCertificate = '''
-----BEGIN CERTIFICATE-----
MIIBlTCCATqgAwIBAgIUDCIMZmLaGuztML9rgysm7dgAjd4wCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLVGVzdCBicmlkZ2UwIBcNMjYxMDI0MDEyNDQ2WhgPMjEyNjA5
MzAwMTI0NDZaMBYxFDASBgNVBAMMC1Rlc3QgYnJpZGdlMFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEVbRLRG+w/+t4/gylU2qzRXbYJuuY+naspudE72rpdynfCo6j
mXQzy9ban3Gr0apQTyPgDnCm/8u3i4Xj0DGTkqNkMGIwHQYDVR0OBBYEFI8Kwcz2
RICh9P7MNeIj+dFyzz4CMB8GA1UdIwQYMBaAFI8Kwcz2RICh9P7MNeIj+dFyzz4C
MA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0RBAgwBocEfwAAATAKBggqhkjOPQQDAgNJ
ADBGAiEAkt6gynJJY4JknfXk1fFU395WCHdbYy7/E7+Jhl1O0/ICIQDnl/A0lvYC
L0lHLsDmVP0ed/ASQoQn6NDzEG18XMI9yw==
-----END CERTIFICATE-----
''';

/// The private key of [selfSignedCertificate]. It protects nothing.
const selfSignedKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgayI0U137LqCgP4cq
cH9k77RtbPkijbtgp2Aljo8+emKhRANCAARVtEtEb7D/63j+DKVTarNFdtgm65j6
dqym50Tvaul3Kd8KjqOZdDPL1tqfcavRqlBPI+AOcKb/y7eLhePQMZOS
-----END PRIVATE KEY-----
''';

/// A server context that presents [selfSignedCertificate].
SecurityContext selfSignedContext() => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(selfSignedCertificate))
  ..usePrivateKeyBytes(utf8.encode(selfSignedKey));
