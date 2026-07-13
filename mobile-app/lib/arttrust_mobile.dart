/// ArtTrust mobile app — Piano C on the dna424_client SDK.
///
/// The Flutter app's logic ported onto the SDK (DEVELOPMENT_PLAN §8, CUTOVER.md
/// step 3), replacing ArtTrust 1.0's mocked NFC provisioning with the real EV2
/// flow. It does NO crypto itself: it builds the opaque ArtTrust binding, the
/// artist's key (in [SecureKeyStore]) signs it, and AttestCore attests. A screen
/// is a thin wrapper over [ArtTrustMobile] (see README.md).
library arttrust_mobile;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dna424_client/dna424_client.dart';

/// ArtTrust's verdict over AttestCore's three independent booleans.
enum Verdict { authentic, counterfeit, replayed, unverifiedArtist }

Verdict verdictOf(VerifyResult v) {
  if (!v.chipAuthentic) return Verdict.counterfeit;
  if (!v.notReplayed) return Verdict.replayed;
  if (!v.issuerVerified) return Verdict.unverifiedArtist;
  return Verdict.authentic;
}

/// The ArtTrust domain binding: SHA-256(uid ‖ 0x1f ‖ title ‖ 0x1f ‖ artist_id).
/// Byte-identical to the Python backend and the web portal (pinned in
/// test/binding_test.dart) so a tag minted on mobile matches one minted on web.
List<int> arttrustBinding(String uid, String title, String artistId) {
  final bytes = <int>[
    ...utf8.encode(uid),
    0x1f,
    ...utf8.encode(title),
    0x1f,
    ...utf8.encode(artistId),
  ];
  return sha256.convert(bytes).bytes;
}

class ArtTrustMobile {
  ArtTrustMobile({
    required AttestClient client,
    required IdentityService identity,
    TagProvisioner? provisioner,
  })  : _client = client,
        _identity = identity,
        _provisioner = provisioner ?? TagProvisioner();

  final AttestClient _client;
  final IdentityService _identity;
  final TagProvisioner _provisioner;

  /// Enrol the artist: a device-bound identity + an AttestCore issuer. Returns
  /// the issuer id and its bearer token (needed to authenticate provisioning).
  Future<({String issuerId, String token})> enrollArtist() async {
    final publicKeyHex = await _identity.createIdentity();
    return _client.registerIssuer(publicKeyHex);
  }

  /// Mint a tag for an artwork in ONE tap session: read the chip's UID → build
  /// binding → sign on device → AttestCore provisions (authenticated with
  /// [token]) → write the ArtTrust data record + SDM config onto the chip via
  /// the real EV2 flow. The session is held until the tag leaves the field.
  Future<void> mintArtwork({
    required String issuerId,
    required String token,
    required String title,
    required String artistId,
    void Function(String)? onStatus,
  }) async {
    await _provisioner.withArtTag((session) async {
      final binding = arttrustBinding(session.uid, title, artistId);
      final signatureHex = await _identity.signBinding(binding);
      if (signatureHex == null) {
        throw StateError('no identity: enrol the artist first');
      }
      onStatus?.call('Registering the artwork');
      final prov =
          await AttestClient(_client.baseUrl, bearerToken: token).provision(
        uid: session.uid,
        issuerId: issuerId,
        bindingPayloadHex: hex.encode(binding),
        signatureHex: signatureHex,
      );
      await session.provisionSdm(
        chipKeyHex: prov['chip_key_hex'] as String,
        onStatus: onStatus,
      );
    }, onStatus: onStatus);
  }

  /// Demo "mint" without writing a physical chip: enrol an artist + provision,
  /// returning the short-lived ChipKey so the app can simulate taps
  /// ([tapAndVerify]). The real flow ([mintArtwork]) also writes the SDM config
  /// onto the chip over NFC.
  Future<({String issuerId, String uid, String chipKeyHex})> studioMint({
    required String uid,
    required String title,
    required String artistId,
  }) async {
    final reg = await enrollArtist();
    final binding = arttrustBinding(uid, title, artistId);
    final signatureHex = await _identity.signBinding(binding);
    if (signatureHex == null) throw StateError('signing failed');
    final prov =
        await AttestClient(_client.baseUrl, bearerToken: reg.token).provision(
      uid: uid,
      issuerId: reg.issuerId,
      bindingPayloadHex: hex.encode(binding),
      signatureHex: signatureHex,
    );
    return (
      issuerId: reg.issuerId,
      uid: uid,
      chipKeyHex: prov['chip_key_hex'] as String,
    );
  }

  /// Verify a scanned tag and map to the ArtTrust verdict.
  Future<Verdict> verifyScan(String uid, int ctr, String cmacHex) async {
    final result = await _client.verify(uid, ctr, cmacHex);
    return verdictOf(result);
  }

  /// Verify a tag, returning the verdict AND the raw three-boolean result.
  Future<({Verdict verdict, VerifyResult result})> verifyTag(
      String uid, int ctr, String cmacHex) async {
    final result = await _client.verify(uid, ctr, cmacHex);
    return (verdict: verdictOf(result), result: result);
  }

  /// Visitor flow: tap an NTAG 424 DNA tag, read the ArtTrust record it
  /// presents (u/c/m mirrored fresh by SDM), and verify it. Returns null when
  /// the tag carries no usable record.
  Future<({Verdict verdict, VerifyResult result})?> scanAndVerify() async {
    final data = await _provisioner.withArtTag((s) => s.readData());
    if (data == null) return null;
    if (data.legacyUrl != null) {
      final q = Uri.parse(data.legacyUrl!).queryParameters;
      return verifyTag(
          q['u'] ?? '', int.tryParse(q['c'] ?? '0') ?? 0, q['m'] ?? '');
    }
    return verifyTag(data.uid ?? '', data.ctr, data.cmacHex);
  }

  /// Simulate a tap: from the short-lived ChipKey, compute the CMAC a real chip
  /// would mirror, then verify — the whole loop, on the device. Pass [tamper] to
  /// forge a wrong CMAC (→ counterfeit).
  Future<({Verdict verdict, VerifyResult result, String cmac})> tapAndVerify({
    required String uid,
    required String chipKeyHex,
    required int ctr,
    bool tamper = false,
  }) async {
    final chipKey = Uint8List.fromList(hex.decode(chipKeyHex));
    final uidBytes = Uint8List.fromList(hex.decode(uid));
    var cmac = hex.encode(Sdm.computeSdmCmac(chipKey, uidBytes, ctr));
    if (tamper) cmac = '00${cmac.substring(2)}';
    final result = await _client.verify(uid, ctr, cmac);
    return (verdict: verdictOf(result), result: result, cmac: cmac);
  }
}
