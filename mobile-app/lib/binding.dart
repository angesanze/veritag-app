/// The Veritag domain binding: SHA-256(uid ‖ 0x1f ‖ title ‖ 0x1f ‖ artist_id).
///
/// Byte-identical to the backend (veritag-core `arttrust/binding.py`) and the
/// web portal, pinned by test/binding_test.dart and the cross-SDK conformance
/// vectors — a work minted on mobile must verify everywhere. The construction
/// (and its unit-separator framing) is protocol: names may rebrand, bytes don't.
library binding;

import 'dart:convert';

import 'package:crypto/crypto.dart';

List<int> veritagBinding(String uid, String title, String artistId) {
  final bytes = <int>[
    ...utf8.encode(uid),
    0x1f,
    ...utf8.encode(title),
    0x1f,
    ...utf8.encode(artistId),
  ];
  return sha256.convert(bytes).bytes;
}
