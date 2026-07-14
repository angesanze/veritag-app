/// Dart client for arttrust-api (Piano C) — the domain backend the app talks to.
///
/// The artist flows (enrol, find a curator, request the blue check, mint) and the
/// visitor passport all go through here. Crypto stays in the SDK: keys are made
/// and signing happens on-device (IdentityService); this only carries domain JSON.
library arttrust_api;

import 'dart:convert';

import 'package:http/http.dart' as http;

class ArtTrustApiError implements Exception {
  ArtTrustApiError(this.status, this.detail);
  final int status;
  final String detail;
  @override
  String toString() => '$status — $detail';
}

class Curator {
  Curator(this.curatorId, this.name, this.bio);
  final String curatorId;
  final String name;
  final String bio;
  factory Curator.fromJson(Map<String, dynamic> j) =>
      Curator(j['curator_id'] as String, j['name'] as String, (j['bio'] ?? '') as String);
}

class ArtistProfile {
  ArtistProfile(this.artistId, this.name, this.issuerId, this.verified, this.verifiedBy);
  final String artistId;
  final String name;
  final String issuerId;
  final bool verified;
  final List<Curator> verifiedBy;
  factory ArtistProfile.fromJson(Map<String, dynamic> j) => ArtistProfile(
        j['artist_id'] as String,
        j['name'] as String,
        j['issuer_id'] as String,
        (j['verified'] ?? false) as bool,
        ((j['verified_by'] ?? []) as List)
            .map((c) => Curator.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

class VerificationReq {
  VerificationReq(this.requestId, this.code, this.status, this.expiresAt);
  final String requestId;
  final String? code;
  final String status;
  final double expiresAt;
  factory VerificationReq.fromJson(Map<String, dynamic> j) => VerificationReq(
        j['request_id'] as String,
        j['code'] as String?,
        j['status'] as String,
        (j['expires_at'] as num).toDouble(),
      );
}

class MintResult {
  MintResult(this.uid, this.chipKeyHex, this.bindingId);
  final String uid;
  final String chipKeyHex;
  final String bindingId;
  factory MintResult.fromJson(Map<String, dynamic> j) =>
      MintResult(j['uid'] as String, j['chip_key_hex'] as String, j['binding_id'] as String);
}

class ExhibitionRef {
  ExhibitionRef(this.title, this.startsAt, this.curatorName, this.venue);
  final String title;
  final String startsAt;
  final String? curatorName;
  final String venue;
  factory ExhibitionRef.fromJson(Map<String, dynamic> j) => ExhibitionRef(
        j['title'] as String,
        (j['starts_at'] ?? '') as String,
        j['curator_name'] as String?,
        (j['venue'] ?? '') as String,
      );
}

class Passport {
  Passport({
    required this.uid,
    required this.ctr,
    required this.verdict,
    required this.reason,
    required this.chipAuthentic,
    required this.notReplayed,
    required this.issuerVerified,
    required this.artworkTitle,
    required this.artworkDescription,
    required this.artworkImage,
    required this.artworkVideoUrl,
    required this.bindingId,
    required this.artistName,
    required this.artistVerified,
    required this.verifiedBy,
    required this.exhibitions,
  });
  final String uid;            // chip UID this passport belongs to
  final int ctr;               // SDM read counter — how many taps this one is
  final String verdict;
  final String reason;         // server's explanation when a check fails
  final bool chipAuthentic;
  final bool notReplayed;
  final bool issuerVerified;
  final String? artworkTitle;
  final String artworkDescription;
  final String artworkImage;   // data URL added by the artist, '' if none
  final String artworkVideoUrl;
  final String bindingId;      // the attested chip↔work binding
  final String? artistName;
  final bool artistVerified;
  final List<String> verifiedBy;
  final List<ExhibitionRef> exhibitions;

  factory Passport.fromJson(Map<String, dynamic> j) {
    final artwork = j['artwork'] as Map<String, dynamic>?;
    final artist = j['artist'] as Map<String, dynamic>?;
    return Passport(
      uid: (j['uid'] ?? '') as String,
      ctr: (j['ctr'] ?? 0) as int,
      verdict: j['verdict'] as String,
      reason: (j['reason'] ?? '') as String,
      chipAuthentic: j['chip_authentic'] as bool,
      notReplayed: j['not_replayed'] as bool,
      issuerVerified: j['issuer_verified'] as bool,
      artworkTitle: artwork?['title'] as String?,
      artworkDescription: (artwork?['description'] ?? '') as String,
      artworkImage: (artwork?['image_data_url'] ?? '') as String,
      artworkVideoUrl: (artwork?['video_url'] ?? '') as String,
      bindingId: (artwork?['binding_id'] ?? '') as String,
      artistName: artist?['name'] as String?,
      artistVerified: (j['artist_verified'] ?? false) as bool,
      verifiedBy: ((j['verified_by'] ?? []) as List)
          .map((c) => (c as Map<String, dynamic>)['name'] as String)
          .toList(),
      exhibitions: ((j['exhibitions'] ?? []) as List)
          .map((e) => ExhibitionRef.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ArtTrustApi {
  ArtTrustApi(this.baseUrl, {http.Client? client}) : _http = client ?? http.Client();
  final String baseUrl;
  final http.Client _http;

  String get _base => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Future<dynamic> _json(http.Response r) async {
    if (r.statusCode >= 400) {
      String detail = r.reasonPhrase ?? 'error';
      try {
        detail = (jsonDecode(r.body) as Map<String, dynamic>)['detail'] as String? ?? detail;
      } catch (_) {}
      throw ArtTrustApiError(r.statusCode, detail);
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<http.Response> _post(String path, Object body) => _http.post(
        Uri.parse('$_base$path'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

  Future<bool> health() async {
    try {
      // /meta, not /healthz: Google's frontend swallows /healthz on *.run.app.
      final r = await _http.get(Uri.parse('$_base/meta')).timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// The AttestCore base URL this deployment talks to (null if unreachable).
  Future<String?> attestUrl() async {
    try {
      final r = await _http.get(Uri.parse('$_base/meta')).timeout(const Duration(seconds: 5));
      return (jsonDecode(r.body) as Map<String, dynamic>)['attest_url'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<List<Curator>> listCurators() async {
    final r = await _http.get(Uri.parse('$_base/curators'));
    return ((await _json(r)) as List).map((c) => Curator.fromJson(c as Map<String, dynamic>)).toList();
  }

  Future<ArtistProfile> enrollArtist(String name, String publicKeyHex) async {
    final r = await _post('/artists', {'name': name, 'public_key_hex': publicKeyHex});
    return ArtistProfile.fromJson(await _json(r) as Map<String, dynamic>);
  }

  Future<ArtistProfile> getArtist(String artistId) async {
    final r = await _http.get(Uri.parse('$_base/artists/$artistId'));
    return ArtistProfile.fromJson(await _json(r) as Map<String, dynamic>);
  }

  Future<VerificationReq> requestVerification(String artistId, String curatorId) async {
    final r = await _post('/verifications', {'artist_id': artistId, 'curator_id': curatorId});
    return VerificationReq.fromJson(await _json(r) as Map<String, dynamic>);
  }

  Future<MintResult> mintArtwork(
    String artistId,
    String uid,
    String title,
    String signatureHex, {
    String description = '',
    String imageDataUrl = '',
    String videoUrl = '',
  }) async {
    final r = await _post('/artworks', {
      'artist_id': artistId,
      'uid': uid,
      'title': title,
      'signature_hex': signatureHex,
      'description': description,
      'image_data_url': imageDataUrl,
      'video_url': videoUrl,
    });
    return MintResult.fromJson(await _json(r) as Map<String, dynamic>);
  }

  Future<Passport> passport(String u, int c, String mHex, {int kv = 1}) async {
    final uri = Uri.parse('$_base/passport').replace(queryParameters: {
      'u': u,
      'c': '$c',
      'm': mHex,
      'kv': '$kv',
    });
    final r = await _http.get(uri);
    return Passport.fromJson(await _json(r) as Map<String, dynamic>);
  }

  /// Resolve a tag URL to its passport. Accepts both shapes:
  ///   …/t/<uid>                     (plain-written tag → record view)
  ///   …/verify?u=&c=&m=  |  …/passport?u=…  (SDM tag → live verify)
  Future<Passport> passportUrl(String url) {
    final uri = Uri.parse(url);
    final q = uri.queryParameters;
    var u = q['u'] ?? '';
    final segs = uri.pathSegments;
    if (u.isEmpty && segs.length >= 2 && segs[segs.length - 2] == 't') {
      u = segs.last;
    }
    return passport(u, int.tryParse(q['c'] ?? '0') ?? 0, q['m'] ?? '',
        kv: int.tryParse(q['kv'] ?? '1') ?? 1);
  }
}
