import 'dart:async';
import 'dart:convert';

import 'package:dna424_client/dna424_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'arttrust_api.dart';
import 'arttrust_mobile.dart' show arttrustBinding;

void main() => runApp(const ArtTrustApp());

// ── palette ────────────────────────────────────────────────────────────────
const _bg = Color(0xFF08070D);
const _ink = Color(0xFFF3F1FB);
const _muted = Color(0xFF9C9AB6);
const _faint = Color(0xFF6A6783);
const _violet = Color(0xFF9A82FF);
const _violetDeep = Color(0xFF7C5CFF);
const _gold = Color(0xFFD8B46A);
const _blue = Color(0xFF4A90FF);
const _green = Color(0xFF36D399);
const _amber = Color(0xFFF4B740);
const _red = Color(0xFFFF5C72);
const _hair = Color(0x12FFFFFF);

// The cloud deployment (Cloud Run). For local dev, change it in Settings to
// your machine's LAN IP, e.g. http://192.168.1.181:8090.
const _defaultBase = 'https://veritag-api-484395315892.europe-west8.run.app';
const _kArtistId = 'artist_id';
const _kArtistName = 'artist_name';

/// Where an in-place NFC flow is: the scanner ring itself narrates the whole
/// exchange — no sheet, no dialog.
enum NfcPhase { idle, searching, working }

TextStyle _serif(double size, [FontWeight w = FontWeight.w700, Color c = _ink]) =>
    TextStyle(fontFamily: 'serif', fontSize: size, fontWeight: w, color: c, letterSpacing: -0.3, height: 1.15);

String _msg(Object e) => e is ArtTrustApiError ? e.detail : e.toString().replaceFirst('Exception: ', '');
String _initials(String n) => n.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();

ArtistProfile _cachedProfile(String id, String name) => ArtistProfile(id, name, '', false, const <Curator>[]);

BoxDecoration _pageGradient() => const BoxDecoration(
      gradient: RadialGradient(center: Alignment(0.95, -0.95), radius: 1.4, colors: [Color(0x3329203F), _bg], stops: [0.0, 0.62]),
    );

class ArtTrustApp extends StatelessWidget {
  const ArtTrustApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: _violet, brightness: Brightness.dark).copyWith(surface: _bg, primary: _violet);
    InputBorder border(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ArtTrust',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: scheme,
        fontFamily: 'Roboto',
        splashFactory: InkRipple.splashFactory,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          hintStyle: const TextStyle(color: _faint),
          border: border(Colors.transparent),
          enabledBorder: border(_hair),
          focusedBorder: border(_violet, 1.4),
          isDense: true,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ── home: one organic experience ────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _identity = IdentityService(SecureKeyStore());
  final _provisioner = TagProvisioner();
  String _base = _defaultBase;
  bool? _online;
  ArtistProfile? _artist;
  bool _loading = true;
  String _busy = '';
  String? _error;   // real failures (network, backend) — red
  String? _notice;  // calm outcomes (blank tag, not registered) — never red
  NfcPhase _nfc = NfcPhase.idle;
  String _nfcStatus = '';
  bool _nfcCancelled = false;

  ArtTrustApi _api() => ArtTrustApi(_base.trim());
  Timer? _timer;

  /// Channel to MainActivity: tags tapped OUTSIDE an in-app scan land here
  /// (Android dispatches our external-type NDEF record to the app, never to a
  /// browser — the record is data, not a link).
  static const _nfcIntents = MethodChannel('arttrust/nfc');

  @override
  void initState() {
    super.initState();
    _ping();
    _loadArtist();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _ping());
    _nfcIntents.setMethodCallHandler((call) async {
      if (call.method == 'tag') _passportFromPayload(call.arguments as String?);
    });
    // Cold start from a tag tap: pick up the payload the launch intent carried.
    _nfcIntents
        .invokeMethod<String>('takeLaunchPayload')
        .then(_passportFromPayload)
        .catchError((_) => null); // desktop / no platform side
  }

  /// Show the passport for a tag delivered via the OS (tap-to-open).
  void _passportFromPayload(String? payload) {
    if (payload == null || !mounted || _busy.isNotEmpty) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return; // studio/onboarding open
    final d = parseArtTagPayload(payload);
    if (d == null) return;
    setState(() { _error = null; _notice = null; _busy = 'scan'; });
    () async {
      try {
        final p = d.sdmActive
            ? await _api().passport(d.uid ?? '', d.ctr, d.cmacHex)
            : await _api().passport(d.uid ?? '', 0, '');
        if (mounted) _openPassport(p);
      } catch (e) {
        if (mounted) setState(() => _error = _msg(e));
      } finally {
        if (mounted) setState(() => _busy = '');
      }
    }();
  }

  void _openPassport(Passport p) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PassportPage(passport: p)));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _ping() async {
    final ok = await _api().health();
    if (mounted) setState(() => _online = ok);
  }

  Future<void> _loadArtist() async {
    // The persisted artist_id is the enrollment marker (written at enrol,
    // cleared only by the guarded reset in Settings).
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_kArtistId);
      final name = prefs.getString(_kArtistName) ?? 'Artist';
      ArtistProfile? p;
      if (id != null) {
        try { p = await _api().getArtist(id); } catch (_) { p = _cachedProfile(id, name); }
      }
      if (mounted) setState(() { _artist = p; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _persist(ArtistProfile p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kArtistId, p.artistId);
    await prefs.setString(_kArtistName, p.name);
  }

  Future<void> _resetIdentity() async {
    await _identity.deleteIdentity();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kArtistId);
    await prefs.remove(_kArtistName);
    if (mounted) setState(() => _artist = null);
  }

  Future<void> _scan() async {
    // Tap while searching = cancel. Taps while the chip is being worked are ignored.
    if (_nfc == NfcPhase.searching) { _nfcCancelled = true; _provisioner.cancel(); return; }
    if (_nfc == NfcPhase.working) return;
    setState(() { _error = null; _notice = null; _nfc = NfcPhase.searching; _nfcStatus = ''; _nfcCancelled = false; });
    // One tap session: prove the chip is a 424 DNA, read its ArtTrust record
    // (SDM mirrors fresh u/c/m), hold the session until the phone is lifted so
    // the OS never re-dispatches the tag. The HTTP lookup happens afterwards.
    try {
      final read = await _provisioner.withArtTag(
        (s) async => (uid: s.uid, data: await s.readData()),
        onStatus: (m) {
          if (!mounted) return;
          if (_nfc == NfcPhase.searching) HapticFeedback.mediumImpact();
          setState(() { _nfc = NfcPhase.working; _nfcStatus = m; });
        },
      );
      if (!mounted) return;
      // Tag already left the field here — the ring flips green ("lift") while
      // the passport is fetched.
      setState(() => _nfcStatus = 'Tag read — you can lift the phone');
      final d = read.data;
      // A live SDM mirror gives the full cryptographic verdict; anything else
      // (blank tag, legacy URL, half-provisioned) falls back to the record view.
      final p = d != null && d.sdmActive
          ? await _api().passport(d.uid ?? read.uid, d.ctr, d.cmacHex)
          : d?.legacyUrl != null
              ? await _api().passportUrl(d!.legacyUrl!)
              : await _api().passport(read.uid, 0, '');
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      _openPassport(p);
    } catch (e) {
      if (!mounted) return;
      if (_nfcCancelled) return; // user backed out — nothing to report
      HapticFeedback.heavyImpact();
      // A genuine 424 DNA that simply isn't in the registry yet is not an
      // error — it's a blank canvas. Tell that story calmly, not in red.
      if (e is ArtTrustApiError && e.status == 404) {
        setState(() => _notice =
            'This tag is genuine but still blank — no artwork has been bound to it yet. An artist can sign it from the Studio.');
      } else {
        setState(() => _error = _msg(e));
      }
    } finally {
      if (mounted) setState(() { _nfc = NfcPhase.idle; _nfcStatus = ''; });
    }
  }

  Future<void> _openStudio() async {
    final a = _artist;
    if (a == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StudioPage(
        api: _api, identity: _identity, provisioner: _provisioner, base: _base, artist: a,
        onArtistChanged: (p) { _persist(p); setState(() => _artist = p); },
      ),
    ));
    _loadArtist(); // pick up anything that changed while in the studio
  }

  Future<void> _startOnboarding() async {
    final p = await Navigator.of(context).push<ArtistProfile>(MaterialPageRoute(
      builder: (_) => OnboardingPage(api: _api, identity: _identity),
    ));
    if (p != null) {
      await _persist(p);
      setState(() => _artist = p);
      if (mounted) _openStudio();
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12111C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _SettingsSheet(
        base: _base,
        online: _online,
        provisioner: _provisioner,
        api: _api,
        artist: _artist,
        onChanged: (v) => setState(() => _base = v),
        onArtistChanged: (p) { _persist(p); setState(() => _artist = p); },
        onReset: () { _resetIdentity(); Navigator.of(context).pop(); },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: _pageGradient(),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
            children: [
              _topBar(),
              const SizedBox(height: 26),
              Center(child: Text('Every artwork\ntells the truth.', textAlign: TextAlign.center, style: _serif(30))),
              const SizedBox(height: 8),
              const Center(child: Text('Tap an ArtTrust tag to read its passport.', style: TextStyle(color: _muted, fontSize: 14))),
              const SizedBox(height: 30),
              Center(child: _NfcScanner(label: 'Hold near an artwork', sublabel: 'no sign-up needed', color: _gold, phase: _nfc, status: _nfcStatus, onTap: _scan)),
              const SizedBox(height: 24),
              if (_error != null) Center(child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13.5)))),
              if (_notice != null)
                _Glow(color: _gold, child: Row(children: [
                  const Icon(Icons.brush_rounded, color: _gold, size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_notice!, style: const TextStyle(color: _muted, fontSize: 13, height: 1.5))),
                ])),
              const SizedBox(height: 18),
              _studioEntry(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), gradient: const LinearGradient(colors: [_violet, _gold])),
            alignment: Alignment.center,
            child: const Text('A', style: TextStyle(color: _bg, fontWeight: FontWeight.w800, fontSize: 20, fontFamily: 'serif')),
          ),
          const SizedBox(width: 11),
          Text('ArtTrust', style: _serif(23)),
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300), width: 8, height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _online == null ? _faint : _online! ? _green : _red),
          ),
          IconButton(onPressed: _openSettings, icon: const Icon(Icons.tune_rounded, color: _muted, size: 22), tooltip: 'Settings'),
        ]),
      );

  Widget _studioEntry() {
    if (_loading) return const SizedBox(height: 56);
    final a = _artist;
    if (a == null) {
      return GestureDetector(
        onTap: _startOnboarding,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [_violet.withValues(alpha: 0.14), Colors.transparent]),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _violet.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), gradient: const LinearGradient(colors: [_violet, _gold])),
              child: const Icon(Icons.draw_rounded, color: _bg, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Are you an artist?', style: _serif(16.5)),
              const Text('Create your identity and sign your works.', style: TextStyle(color: _muted, fontSize: 12.5)),
            ])),
            const Icon(Icons.arrow_forward_rounded, color: _muted, size: 20),
          ]),
        ),
      );
    }
    return GestureDetector(
      onTap: _openStudio,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _hair),
        ),
        child: Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), gradient: const LinearGradient(colors: [_gold, _violet])),
            alignment: Alignment.center,
            child: Text(_initials(a.name), style: const TextStyle(color: _bg, fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis, style: _serif(16.5))),
              if (a.verified) ...[const SizedBox(width: 6), const _BlueCheck()],
            ]),
            Text(a.verified ? 'Your studio · verified artist' : 'Your studio', style: const TextStyle(color: _muted, fontSize: 12.5)),
          ])),
          const Icon(Icons.arrow_forward_rounded, color: _muted, size: 20),
        ]),
      ),
    );
  }

}

// ── onboarding (first run only, pushed) ─────────────────────────────────────
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.api, required this.identity});
  final ArtTrustApi Function() api;
  final IdentityService identity;
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _name = TextEditingController(text: 'Wassily Kandinsky');
  int _step = 0;
  ArtistProfile? _profile;
  String _busy = '';
  String? _error;

  @override
  void dispose() { _name.dispose(); super.dispose(); }

  void _enroll() async {
    setState(() { _busy = 'enroll'; _error = null; });
    try {
      final pub = await widget.identity.createIdentity();
      final p = await widget.api().enrollArtist(_name.text.trim(), pub);
      if (mounted) setState(() { _profile = p; _step = 1; });
    } catch (e) { if (mounted) setState(() => _error = _msg(e)); }
    finally { if (mounted) setState(() => _busy = ''); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: _pageGradient(),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _step == 0 ? _intro() : _verifyStep(),
          ),
        ),
      ),
    );
  }

  Widget _intro() => ListView(
        key: const ValueKey(0),
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 60),
        children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back_rounded, color: _muted)),
          ]),
          const SizedBox(height: 8),
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), gradient: const LinearGradient(colors: [_violet, _gold])),
            child: const Icon(Icons.draw_rounded, color: _bg, size: 28),
          ),
          const SizedBox(height: 22),
          Text('Sign your art,\nforever.', style: _serif(34)),
          const SizedBox(height: 14),
          const Text(
            'One identity, created once. It lives only in your phone’s secure enclave and signs every work you mint — '
            'paired with a curator’s blue check.',
            style: TextStyle(color: _muted, fontSize: 15, height: 1.55),
          ),
          const SizedBox(height: 30),
          const _Label('Your name'),
          const SizedBox(height: 8),
          TextField(controller: _name),
          const SizedBox(height: 18),
          _PrimaryButton(label: 'Create your artist identity', busy: _busy == 'enroll', onTap: _enroll),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13.5))),
          const SizedBox(height: 18),
          const Center(child: Text('You’ll only do this once.', style: TextStyle(color: _faint, fontSize: 12.5))),
        ],
      );

  Widget _verifyStep() {
    final p = _profile!;
    return ListView(
      key: const ValueKey(1),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 60),
      children: [
        Row(children: [
          const Icon(Icons.check_circle_rounded, color: _green, size: 26),
          const SizedBox(width: 10),
          Expanded(child: Text('Identity created', style: _serif(24))),
        ]),
        const SizedBox(height: 10),
        const Text('Optional: get a curator’s blue check now. You can also do this anytime later from Settings.',
            style: TextStyle(color: _muted, fontSize: 14.5, height: 1.5)),
        const SizedBox(height: 24),
        VerificationPanel(api: widget.api, profile: p, onVerified: (fresh) => setState(() => _profile = fresh)),
        const SizedBox(height: 26),
        _PrimaryButton(
          label: p.verified ? 'Enter your studio' : 'Skip for now — enter your studio',
          onTap: () => Navigator.of(context).pop(_profile),
        ),
      ],
    );
  }
}

// ── studio (the artist's room) ───────────────────────────────────────────────
class StudioPage extends StatefulWidget {
  const StudioPage({
    super.key, required this.api, required this.identity, required this.provisioner,
    required this.base, required this.artist, required this.onArtistChanged,
  });
  final ArtTrustApi Function() api;
  final IdentityService identity;
  final TagProvisioner provisioner;
  final String base;
  final ArtistProfile artist;
  final void Function(ArtistProfile) onArtistChanged;
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  final _title = TextEditingController(text: 'Composition VIII');
  final _desc = TextEditingController();
  final _video = TextEditingController();
  final _picker = ImagePicker();
  late ArtistProfile _artist = widget.artist;
  Uint8List? _photo;          // downscaled JPEG bytes
  MintResult? _mint;
  MintResult? _pendingMint;   // minted on the server, chip provisioning unfinished
  String _busy = '';
  String? _error;
  NfcPhase _nfc = NfcPhase.idle;
  String _nfcStatus = '';
  bool _nfcCancelled = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() { _title.dispose(); _desc.dispose(); _video.dispose(); super.dispose(); }

  Future<void> _refresh() async {
    try {
      final fresh = await widget.api().getArtist(_artist.artistId);
      if (mounted) { setState(() => _artist = fresh); widget.onArtistChanged(fresh); }
    } catch (_) {}
  }

  Future<void> _guard(String tag, Future<void> Function() fn) async {
    setState(() { _busy = tag; _error = null; });
    try { await fn(); } catch (e) { if (mounted) setState(() => _error = _msg(e)); }
    finally { if (mounted) setState(() => _busy = ''); }
  }

  Future<void> _pickPhoto() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF12111C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.photo_camera_rounded, color: _gold),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded, color: _violet),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (src == null) return;
    // Downscaled at pick time so the data URL stays well under the API cap.
    final x = await _picker.pickImage(source: src, maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (mounted) setState(() => _photo = bytes);
  }

  void _scanAndMint() async {
    // Tap while searching = cancel; taps while the chip is being written are ignored.
    if (_nfc == NfcPhase.searching) { _nfcCancelled = true; widget.provisioner.cancel(); return; }
    if (_nfc == NfcPhase.working) return;
    // ONE tap session, narrated by the scanner ring itself: prove 424 DNA
    // silicon → mint on the server (tag held) → write the ArtTrust data record
    // → enable SDM over EV2 → hold the session until the phone is lifted. If
    // provisioning dies mid-way the mint is kept and the next tap on the SAME
    // tag resumes at the chip-write, without re-minting.
    setState(() { _error = null; _nfc = NfcPhase.searching; _nfcStatus = ''; _nfcCancelled = false; });
    final title = _title.text.trim();
    void status(String m) {
      if (!mounted) return;
      if (_nfc == NfcPhase.searching) HapticFeedback.mediumImpact();
      setState(() { _nfc = NfcPhase.working; _nfcStatus = m; });
    }
    try {
      final m = await widget.provisioner.withArtTag((s) async {
        var mint = _pendingMint;
        if (mint == null || mint.uid != s.uid) {
          final binding = arttrustBinding(s.uid, title, _artist.artistId);
          final sig = await widget.identity.signBinding(binding);
          if (sig == null) throw StateError('signing failed');
          status('Registering the artwork…');
          final photo = _photo;
          mint = await widget.api().mintArtwork(
            _artist.artistId, s.uid, title, sig,
            description: _desc.text.trim(),
            imageDataUrl: photo == null ? '' : 'data:image/jpeg;base64,${base64Encode(photo)}',
            videoUrl: _video.text.trim(),
          );
          _pendingMint = mint;
        } else {
          status('Resuming chip provisioning…');
        }
        await s.provisionSdm(chipKeyHex: mint.chipKeyHex, onStatus: status);
        _pendingMint = null;
        return mint;
      }, onStatus: status);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _mint = m);
    } catch (e) {
      if (!mounted) return;
      if (!_nfcCancelled) {
        HapticFeedback.heavyImpact();
        setState(() => _error = _msg(e));
      }
    } finally {
      if (mounted) setState(() { _nfc = NfcPhase.idle; _nfcStatus = ''; });
    }
  }

  // See the passport exactly as a visitor will when they tap this tag.
  void _previewTap() => _guard('preview', () async {
        final m = _mint;
        if (m == null) return;
        final p = await widget.api().passport(m.uid, 0, '');
        if (mounted) {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PassportPage(passport: p)));
        }
      });

  @override
  Widget build(BuildContext context) {
    final a = _artist;
    final m = _mint;
    return Scaffold(
      body: Container(
        decoration: _pageGradient(),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 60),
            children: [
              Row(children: [
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back_rounded, color: _muted)),
                const Spacer(),
              ]),
              Row(children: [
                Container(
                  width: 54, height: 54,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: const LinearGradient(colors: [_gold, _violet])),
                  alignment: Alignment.center,
                  child: Text(_initials(a.name), style: const TextStyle(color: _bg, fontWeight: FontWeight.w800, fontSize: 18)),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.name, style: _serif(22)),
                  const SizedBox(height: 3),
                  a.verified
                      ? const Row(children: [_BlueCheck(), SizedBox(width: 6), Text('Verified artist', style: TextStyle(color: _blue, fontSize: 12.5, fontWeight: FontWeight.w600))])
                      : const Text('Not yet verified · get the blue check in Settings', style: TextStyle(color: _faint, fontSize: 12)),
                ])),
              ]),
              if (a.verified) ...[const SizedBox(height: 20), _VerifiedBanner(names: a.verifiedBy.map((c) => c.name).toList())],
              const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Divider(color: _hair, height: 1)),

              Text('Sign an artwork', style: _serif(19)),
              const SizedBox(height: 6),
              const Text('Tell the work’s story, then hold your phone to its tag — only genuine NTAG 424 DNA chips are accepted.',
                  style: TextStyle(color: _muted, fontSize: 13.5, height: 1.5)),
              const SizedBox(height: 18),
              const _Label('Title'),
              const SizedBox(height: 8),
              TextField(controller: _title),
              const SizedBox(height: 14),
              const _Label('Description'),
              const SizedBox(height: 8),
              TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(hintText: 'Materials, dimensions, the story behind it…')),
              const SizedBox(height: 14),
              const _Label('Photo'),
              const SizedBox(height: 8),
              _photoField(),
              const SizedBox(height: 14),
              const _Label('Video link (optional)'),
              const SizedBox(height: 8),
              TextField(controller: _video, decoration: const InputDecoration(hintText: 'https://…')),
              const SizedBox(height: 26),
              Center(child: _NfcScanner(label: 'Scan & mint', sublabel: 'hold the phone to the tag', phase: _nfc, status: _nfcStatus, onTap: _scanAndMint)),

              if (m != null) ...[
                const SizedBox(height: 24),
                _Glow(color: _green, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.check_circle_rounded, color: _green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Signed · tag ${_short(m.uid)}', style: _serif(15.5))),
                  ]),
                  const SizedBox(height: 4),
                  const Text('The chip now carries a secured ArtTrust record and mirrors a fresh cryptographic proof on every tap — it is data, not a link: no browser will ever open from it.',
                      style: TextStyle(color: _muted, fontSize: 12.5, height: 1.4)),
                  const SizedBox(height: 14),
                  _QuietButton(label: 'Preview the passport', busy: _busy == 'preview', onTap: _previewTap),
                ])),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13.5))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoField() {
    final photo = _photo;
    return GestureDetector(
      onTap: _pickPhoto,
      child: photo == null
          ? Container(
              height: 110,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _hair),
              ),
              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_photo_alternate_rounded, color: _muted, size: 26),
                SizedBox(height: 6),
                Text('Add a photo of the work', style: TextStyle(color: _faint, fontSize: 12.5)),
              ]),
            )
          : Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(photo, height: 190, width: double.infinity, fit: BoxFit.cover),
              ),
              Positioned(
                top: 8, right: 8,
                child: GestureDetector(
                  onTap: () => setState(() => _photo = null),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ]),
    );
  }

  String _short(String s) => s.length > 10 ? '${s.substring(0, 10)}…' : s;
}

// ── verification panel (onboarding + settings) ──────────────────────────────
class VerificationPanel extends StatefulWidget {
  const VerificationPanel({super.key, required this.api, required this.profile, required this.onVerified});
  final ArtTrustApi Function() api;
  final ArtistProfile profile;
  final void Function(ArtistProfile) onVerified;
  @override
  State<VerificationPanel> createState() => _VerificationPanelState();
}

class _VerificationPanelState extends State<VerificationPanel> {
  List<Curator> _curators = [];
  Curator? _picked;
  VerificationReq? _req;
  String _busy = '';
  String? _error;
  Timer? _poll;

  @override
  void dispose() { _poll?.cancel(); super.dispose(); }

  Future<void> _guard(String tag, Future<void> Function() fn) async {
    setState(() { _busy = tag; _error = null; });
    try { await fn(); } catch (e) { if (mounted) setState(() => _error = _msg(e)); }
    finally { if (mounted) setState(() => _busy = ''); }
  }

  void _find() => _guard('find', () async {
        final cs = await widget.api().listCurators();
        Curator? sel;
        for (final c in cs) { if (c.curatorId == _picked?.curatorId) sel = c; }
        if (mounted) setState(() { _curators = cs; _picked = sel ?? (cs.isNotEmpty ? cs.first : null); });
      });

  void _request() => _guard('request', () async {
        final c = _picked;
        if (c == null) return;
        final r = await widget.api().requestVerification(widget.profile.artistId, c.curatorId);
        if (mounted) setState(() => _req = r);
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
          try {
            final fresh = await widget.api().getArtist(widget.profile.artistId);
            if (fresh.verified) { _poll?.cancel(); if (mounted) { setState(() => _req = null); widget.onVerified(fresh); } }
          } catch (_) {}
        });
      });

  @override
  Widget build(BuildContext context) {
    if (widget.profile.verified) {
      return _VerifiedBanner(names: widget.profile.verifiedBy.map((c) => c.name).toList());
    }
    final req = _req;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Get the blue check', style: _serif(18)),
      const SizedBox(height: 6),
      const Text('Find a curator and request verification. Read them the code in person; when they confirm, you’re verified.',
          style: TextStyle(color: _muted, fontSize: 13, height: 1.5)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: _curators.isEmpty
              ? const Text('Tap “Find curators”.', style: TextStyle(color: _faint, fontSize: 13.5))
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(14), border: Border.all(color: _hair)),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<Curator>(
                      value: _picked, isExpanded: true, dropdownColor: const Color(0xFF15141F),
                      icon: const Icon(Icons.expand_more_rounded, color: _muted),
                      items: _curators.map((c) => DropdownMenuItem(value: c, child: Text(c.name, style: const TextStyle(fontSize: 14.5)))).toList(),
                      onChanged: (c) => setState(() => _picked = c),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 10),
        _QuietButton(label: 'Find curators', busy: _busy == 'find', onTap: _find),
      ]),
      const SizedBox(height: 14),
      _PrimaryButton(label: 'Request verification', busy: _busy == 'request', onTap: _picked != null ? _request : null),
      if (req != null && req.code != null) _CodeReveal(code: req.code!),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: const TextStyle(color: _red, fontSize: 13))),
    ]);
  }
}

// ── passport (full page) ────────────────────────────────────────────────────
/// The artwork's passport, full screen — what a visitor gets for a tap.
///
/// Stateful for one reason: the artist's photo is base64-decoded ONCE here and
/// rendered with gaplessPlayback, so no rebuild (parent pings, animations…)
/// ever re-decodes or flashes it.
class PassportPage extends StatefulWidget {
  const PassportPage({super.key, required this.passport});
  final Passport passport;
  @override
  State<PassportPage> createState() => _PassportPageState();
}

class _PassportPageState extends State<PassportPage> {
  Uint8List? _photo; // decoded once, never again

  @override
  void initState() {
    super.initState();
    final img = widget.passport.artworkImage;
    if (img.startsWith('data:')) {
      try { _photo = base64Decode(img.split(',').last); } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.passport;
    late final Color c; late final IconData icon; late final String title, desc;
    switch (p.verdict) {
      case 'authentic': c = _green; icon = Icons.verified_rounded; title = 'Authentic'; desc = 'Genuine chip, fresh scan, signed by the artist.';
      case 'counterfeit': c = _red; icon = Icons.gpp_bad_rounded; title = 'Counterfeit'; desc = 'The chip’s signature doesn’t match — not the real tag.';
      case 'replayed': c = _amber; icon = Icons.replay_rounded; title = 'Already scanned'; desc = 'Seen before — a replayed or cloned tap.';
      case 'record': c = _gold; icon = Icons.museum_rounded; title = 'On record'; desc = 'This tag carries the work’s identity and provenance.';
      default: c = _amber; icon = Icons.help_rounded; title = 'Unverified artist'; desc = 'Real chip, but the artist is unknown or revoked.';
    }
    final isRecord = p.verdict == 'record';
    final photo = _photo;

    return Scaffold(
      body: Container(
        decoration: _pageGradient(),
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: Stack(children: [
            // Full-bleed artwork header — the protagonist, not a backdrop.
            // Tap it to open full screen with pinch-to-zoom.
            if (photo != null)
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _PhotoViewerPage(photo: photo, title: p.artworkTitle ?? 'Artwork'))),
                child: ShaderMask(
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.white24],
                    stops: [0.0, 0.82, 1.0],
                  ).createShader(r),
                  blendMode: BlendMode.dstIn,
                  child: Image.memory(
                    photo,
                    width: double.infinity, height: 400, fit: BoxFit.cover,
                    gaplessPlayback: true, // never flash on rebuild
                  ),
                ),
              )
            else
              Container(
                height: 210, width: double.infinity,
                decoration: BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [c.withValues(alpha: 0.18), Colors.transparent],
                )),
              ),
            // Zoom affordance — makes "you can open me" explicit.
            if (photo != null)
              Positioned(
                right: 16, bottom: 22,
                child: IgnorePointer(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: _bg.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: _hair),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.zoom_out_map_rounded, color: _ink, size: 14),
                    SizedBox(width: 6),
                    Text('Tap to expand', style: TextStyle(color: _muted, fontSize: 11.5)),
                  ]),
                )),
              ),
            SafeArea(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(children: [
                _CircleIconButton(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: _bg.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: c.withValues(alpha: 0.55)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, color: c, size: 15),
                    const SizedBox(width: 6),
                    Text(title, style: TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ]),
            )),
          ])),
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 48),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── the work ─────────────────────────────────────────────
              if (p.artworkTitle != null) Text(p.artworkTitle!, style: _serif(30)),
              if (p.artistName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Flexible(child: Text('by ${p.artistName}', style: const TextStyle(color: _muted, fontSize: 15))),
                    if (p.artistVerified) ...[
                      const SizedBox(width: 8), const _BlueCheck(), const SizedBox(width: 6),
                      Flexible(child: Text(
                        p.verifiedBy.isEmpty ? 'verified' : 'vouched for by ${p.verifiedBy.join(", ")}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _blue, fontSize: 12.5, fontWeight: FontWeight.w600),
                      )),
                    ],
                  ]),
                ),
              if (p.artworkDescription.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(p.artworkDescription, style: const TextStyle(color: _muted, fontSize: 14, height: 1.6)),
              ],
              if (p.artworkVideoUrl.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(children: [
                  const Icon(Icons.play_circle_outline_rounded, size: 17, color: _gold),
                  const SizedBox(width: 8),
                  Flexible(child: SelectableText(p.artworkVideoUrl, style: const TextStyle(color: _gold, fontSize: 12.5))),
                ]),
              ],

              // ── the verdict, in words ────────────────────────────────
              const SizedBox(height: 26),
              _Glow(color: c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 46, height: 46, decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: c, size: 25)),
                  const SizedBox(width: 13),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: _serif(19)),
                    Text(desc, style: const TextStyle(color: _muted, fontSize: 12.5, height: 1.4)),
                  ])),
                ]),
                if (p.reason.isNotEmpty && p.verdict != 'authentic' && !isRecord)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('Why: ${p.reason}', style: const TextStyle(color: _faint, fontSize: 12, height: 1.4)),
                  ),
                const SizedBox(height: 6),
                if (isRecord)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Icon(Icons.bolt_rounded, size: 18, color: _gold),
                      SizedBox(width: 10),
                      Expanded(child: Text('This view comes from the registry only — tap the physical tag to run the live anti-clone check.',
                          style: TextStyle(color: _muted, fontSize: 12.5, height: 1.4))),
                    ]),
                  )
                else ...[
                  _check(p.chipAuthentic, 'Chip is genuine', 'its one-time cryptographic proof matches'),
                  _check(p.notReplayed, 'Fresh scan', 'this exact tap was never seen before'),
                  _check(p.issuerVerified, 'Artist signature', 'the work is signed by its artist'),
                ],
              ])),

              // ── provenance ───────────────────────────────────────────
              const SizedBox(height: 28),
              Row(children: [
                const Icon(Icons.history_edu_rounded, size: 16, color: _gold),
                const SizedBox(width: 8),
                Text('PROVENANCE · ${p.exhibitions.length}', style: const TextStyle(color: _muted, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 12),
              if (p.exhibitions.isEmpty)
                const Text('Not exhibited yet — its story starts here.', style: TextStyle(color: _faint, fontSize: 12.5))
              else
                ...List.generate(p.exhibitions.length, (i) {
                  final e = p.exhibitions[i];
                  final last = i == p.exhibitions.length - 1;
                  final meta = [
                    if (e.startsAt.isNotEmpty) e.startsAt,
                    if (e.venue.isNotEmpty) e.venue,
                    if (e.curatorName != null && e.curatorName!.isNotEmpty) 'curated by ${e.curatorName!}',
                  ].join('  ·  ');
                  return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Column(children: [
                      Container(width: 9, height: 9, margin: const EdgeInsets.only(top: 4), decoration: BoxDecoration(color: _gold, shape: BoxShape.circle, boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.3), blurRadius: 6, spreadRadius: 2)])),
                      if (!last) Expanded(child: Container(width: 1.5, color: _hair, margin: const EdgeInsets.symmetric(vertical: 3))),
                    ]),
                    const SizedBox(width: 12),
                    Expanded(child: Padding(
                      padding: EdgeInsets.only(bottom: last ? 0 : 14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.title, style: _serif(15, FontWeight.w600)),
                        Text(meta, style: const TextStyle(color: _faint, fontSize: 11.5)),
                      ]),
                    )),
                  ]));
                }),

              // ── tag & proof (the technical passport) ─────────────────
              const SizedBox(height: 28),
              const Row(children: [
                Icon(Icons.memory_rounded, size: 16, color: _violet),
                SizedBox(width: 8),
                Text('TAG & PROOF', style: TextStyle(color: _muted, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              _fact('Chip', 'NTAG 424 DNA · AES-128 · secure dynamic messaging'),
              if (p.uid.isNotEmpty) _fact('Chip UID', p.uid, mono: true),
              if (!isRecord) _fact('Tap number', '#${p.ctr} — the chip counts every read'),
              if (p.bindingId.isNotEmpty) _fact('Binding', p.bindingId, mono: true),
              _fact('Tag content', 'a data record, not a link — only ArtTrust can read it into a passport'),
            ]),
          )),
        ]),
      ),
    );
  }

  Widget _check(bool ok, String label, String hint) => Padding(
        padding: const EdgeInsets.only(top: 11),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 18, color: ok ? _green : _red),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 13.5)),
            Text(hint, style: const TextStyle(color: _faint, fontSize: 11.5, height: 1.3)),
          ])),
        ]),
      );

  Widget _fact(String k, String v, {bool mono = false}) => Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: _faint, fontSize: 12))),
          Expanded(child: SelectableText(v, style: TextStyle(color: _muted, fontSize: 12.5, height: 1.4, fontFamily: mono ? 'monospace' : null))),
        ]),
      );
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: _bg.withValues(alpha: 0.65), shape: BoxShape.circle, border: Border.all(color: _hair)),
          child: Icon(icon, color: _ink, size: 20),
        ),
      );
}

/// The artwork full screen: pinch to zoom (up to 6×), double-tap to zoom in
/// and back out, ✕ to close. Deliberately Hero-free: the flight's destination
/// rect used to collapse before the image decoded, leaving a tiny photo.
class _PhotoViewerPage extends StatefulWidget {
  const _PhotoViewerPage({required this.photo, required this.title});
  final Uint8List photo;
  final String title;
  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  final _zoom = TransformationController();
  TapDownDetails? _lastTap;

  @override
  void dispose() { _zoom.dispose(); super.dispose(); }

  void _toggleZoom() {
    if (_zoom.value != Matrix4.identity()) {
      _zoom.value = Matrix4.identity(); // zoomed → reset
      return;
    }
    // Zoom 2.5× centred on where the user double-tapped.
    final pos = _lastTap?.localPosition ?? Offset.zero;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(-pos.dx * 1.5, -pos.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    // SizedBox.expand is load-bearing: without it the Stack takes its size
    // from the small top bar, collapses to ~200px, and the photo renders as
    // a thumbnail pinned to the top of the screen.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(child: Stack(fit: StackFit.expand, children: [
        GestureDetector(
          onDoubleTapDown: (d) => _lastTap = d,
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _zoom,
            minScale: 1, maxScale: 6,
            child: Image.memory(widget.photo, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
        // Top scrim so the close button and title always read over the photo.
        Positioned(
          top: 0, left: 0, right: 0,
          child: IgnorePointer(child: Container(
            height: 130,
            decoration: const BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            )),
          )),
        ),
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(widget.title, overflow: TextOverflow.ellipsis, style: _serif(17))),
            ]),
          )),
        ),
        // Bottom hint so the gesture is discoverable.
        Positioned(
          left: 0, right: 0, bottom: 26,
          child: IgnorePointer(child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white12),
            ),
            child: const Text('Pinch or double-tap to zoom', style: TextStyle(color: Colors.white70, fontSize: 12)),
          ))),
        ),
      ])),
    );
  }
}

// ── settings sheet ──────────────────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.base, required this.online, required this.provisioner, required this.onChanged,
    this.api, this.artist, this.onArtistChanged, this.onReset,
  });
  final String base;
  final bool? online;
  final TagProvisioner provisioner;
  final void Function(String) onChanged;
  final ArtTrustApi Function()? api;
  final ArtistProfile? artist;
  final void Function(ArtistProfile)? onArtistChanged;
  final VoidCallback? onReset;
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.base);
  bool? _nfc;
  late ArtistProfile? _artist = widget.artist;
  NfcDiagnostics? _diag;
  bool _diagBusy = false;

  @override
  void initState() {
    super.initState();
    widget.provisioner.isAvailable().then((v) { if (mounted) setState(() => _nfc = v); });
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  Future<void> _runDiag() async {
    setState(() { _diagBusy = true; _diag = null; });
    final d = await widget.provisioner.diagnose();
    if (mounted) setState(() { _diag = d; _diagBusy = false; });
  }

  Future<void> _confirmReset() async {
    final a = _artist;
    if (a == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _TypedResetDialog(expectedName: a.name),
    );
    if (ok == true) widget.onReset?.call();
  }

  @override
  Widget build(BuildContext context) {
    final a = _artist;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 18, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _hair, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 18),
        Text('Settings', style: _serif(22)),
        const SizedBox(height: 20),

        const _Label('ArtTrust endpoint'),
        const SizedBox(height: 8),
        TextField(controller: _c, onChanged: widget.onChanged),
        const SizedBox(height: 14),
        _statusLine(widget.online == true ? _green : _red, widget.online == null ? 'checking…' : widget.online! ? 'Backend connected' : 'Backend unreachable — check the LAN IP'),
        const SizedBox(height: 9),
        _statusLine(_nfc == true ? _green : _amber, _nfc == null ? 'checking NFC…' : _nfc! ? 'NFC reader available · accepts only NTAG 424 DNA' : 'NFC unavailable on this device'),

        const Padding(padding: EdgeInsets.symmetric(vertical: 22), child: Divider(color: _hair, height: 1)),
        Text('Tag doctor', style: _serif(17)),
        const SizedBox(height: 6),
        const Text('Tap a tag to see exactly what it is — chip model, UID, and whether it’s recognised as an NTAG 424 DNA.',
            style: TextStyle(color: _muted, fontSize: 12.5, height: 1.5)),
        const SizedBox(height: 12),
        _QuietButton(label: '◌  Diagnose a tag', busy: _diagBusy, onTap: _runDiag),
        if (_diag != null) Padding(padding: const EdgeInsets.only(top: 14), child: _DiagCard(d: _diag!)),

        if (a != null && widget.api != null) ...[
          const Padding(padding: EdgeInsets.symmetric(vertical: 22), child: Divider(color: _hair, height: 1)),
          Text('Verification', style: _serif(17)),
          const SizedBox(height: 12),
          VerificationPanel(
            api: widget.api!,
            profile: a,
            onVerified: (p) { setState(() => _artist = p); widget.onArtistChanged?.call(p); },
          ),
          const Padding(padding: EdgeInsets.symmetric(vertical: 22), child: Divider(color: _hair, height: 1)),
          Text('Identity', style: _serif(17)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity, padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(10), border: Border.all(color: _hair)),
            child: Text('${a.name}\n${a.artistId}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: _muted)),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _confirmReset,
            child: Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(color: _red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: _red.withValues(alpha: 0.35))),
              child: const Center(child: Text('Reset identity', style: TextStyle(color: _red, fontWeight: FontWeight.w700, fontSize: 14))),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Resetting deletes your signing key from this device forever. To prevent accidents, you’ll be asked to type your artist name.', style: TextStyle(color: _faint, fontSize: 12, height: 1.5)),
        ] else ...[
          const SizedBox(height: 12),
          const Text('On the phone, set the endpoint to your computer’s LAN IP (e.g. 192.168.1.181) so the device can reach the backend.', style: TextStyle(color: _faint, fontSize: 12, height: 1.5)),
        ],
      ]),
    );
  }

  Widget _statusLine(Color c, String t) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text(t, style: const TextStyle(color: _muted, fontSize: 13))),
      ]);
}

/// The guarded reset: the artist must TYPE their name to arm the button — an
/// identity is not something you lose to a stray tap.
class _TypedResetDialog extends StatefulWidget {
  const _TypedResetDialog({required this.expectedName});
  final String expectedName;
  @override
  State<_TypedResetDialog> createState() => _TypedResetDialogState();
}

class _TypedResetDialogState extends State<_TypedResetDialog> {
  final _input = TextEditingController();
  bool _armed = false;

  @override
  void dispose() { _input.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF15141F),
      title: Text('Reset identity?', style: _serif(18)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'This permanently deletes your signing key from this device. Works you already minted stay authentic, '
          'but this identity — and its blue check — are gone for good.\n',
          style: TextStyle(color: _muted, fontSize: 13.5, height: 1.5),
        ),
        Text('Type “${widget.expectedName}” to confirm:', style: const TextStyle(color: _ink, fontSize: 13.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        TextField(
          controller: _input,
          autofocus: true,
          decoration: InputDecoration(hintText: widget.expectedName),
          onChanged: (v) => setState(() => _armed = v.trim().toLowerCase() == widget.expectedName.trim().toLowerCase()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: _muted))),
        TextButton(
          onPressed: _armed ? () => Navigator.pop(context, true) : null,
          child: Text('Reset forever', style: TextStyle(color: _armed ? _red : _faint, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ── atoms ──────────────────────────────────────────────────────────────────
/// The one and only NFC affordance: the pulsing ring IS the whole flow. While
/// searching, a circular loader orbits the icon; once the tag is found the
/// loader turns amber and the step narration replaces the label. No sheet,
/// no dialog — everything happens around the ring the user already tapped.
class _NfcScanner extends StatefulWidget {
  const _NfcScanner({required this.onTap, required this.label, this.sublabel, this.phase = NfcPhase.idle, this.status = '', this.color = _violet});
  final VoidCallback? onTap;
  final String label;
  final String? sublabel;
  final NfcPhase phase;
  final String status;
  final Color color;
  @override
  State<_NfcScanner> createState() => _NfcScannerState();
}

class _NfcScannerState extends State<_NfcScanner> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final searching = widget.phase == NfcPhase.searching;
    final working = widget.phase == NfcPhase.working;
    final lifting = working && widget.status.contains('lift');
    final accent = lifting ? _green : working ? _amber : widget.color;

    final label = working
        ? (widget.status.isEmpty ? 'Working…' : widget.status)
        : searching
            ? 'Waiting for the tag…'
            : widget.label;
    final sublabel = lifting
        ? 'you can lift the phone'
        : working
            ? 'keep the phone still on the tag'
            : searching
                ? 'hold your phone to the tag · tap to cancel'
                : widget.sublabel;

    return GestureDetector(
      onTap: widget.onTap,
      child: Column(children: [
        SizedBox(
          width: 188, height: 188,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Stack(alignment: Alignment.center, children: [
              for (final d in const [0.0, 0.33, 0.66]) _ring((_ctrl.value + d) % 1.0, accent),
              // The circular loader around the icon — the whole "UI" of a scan.
              if (searching || working)
                SizedBox(
                  width: 112, height: 112,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    strokeCap: StrokeCap.round,
                    valueColor: AlwaysStoppedAnimation(accent),
                    backgroundColor: accent.withValues(alpha: 0.15),
                  ),
                ),
              Container(
                width: 84, height: 84,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [accent, accent.withValues(alpha: 0.55)]), boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 34, spreadRadius: 2)]),
                child: Icon(lifting ? Icons.check_rounded : Icons.contactless_rounded, size: 40, color: Colors.white),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Text(label, key: ValueKey(label), style: _serif(18), textAlign: TextAlign.center),
        ),
        if (sublabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(sublabel,
                style: TextStyle(
                  color: lifting ? _green : working ? _amber : _faint,
                  fontSize: 12.5,
                  fontWeight: working ? FontWeight.w700 : FontWeight.w400,
                )),
          ),
      ]),
    );
  }

  Widget _ring(double t, Color c) {
    final size = 84 + t * 104;
    final opacity = ((1 - t) * 0.45).clamp(0.0, 1.0);
    return Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.withValues(alpha: opacity), width: 1.4)));
  }
}

class _CodeReveal extends StatelessWidget {
  const _CodeReveal({required this.code});
  final String code;
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (_, t, child) => Transform.scale(scale: 0.95 + 0.05 * t.clamp(0, 1), child: Opacity(opacity: t.clamp(0, 1), child: child)),
      child: _Glow(
        color: _blue,
        margin: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('READ THIS CODE TO THE CURATOR', style: TextStyle(color: _muted, fontSize: 10.5, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(code, style: const TextStyle(fontFamily: 'serif', fontSize: 42, fontWeight: FontWeight.w700, letterSpacing: 12, color: Colors.white)),
          const SizedBox(height: 8),
          const Row(children: [
            SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: _blue)),
            SizedBox(width: 10),
            Text('waiting for the curator to confirm…', style: TextStyle(color: _muted, fontSize: 12)),
          ]),
        ]),
      ),
    );
  }
}

class _VerifiedBanner extends StatelessWidget {
  const _VerifiedBanner({required this.names});
  final List<String> names;
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (_, t, child) => Transform.scale(scale: 0.96 + 0.04 * t.clamp(0, 1), child: Opacity(opacity: t.clamp(0, 1), child: child)),
      child: _Glow(
        color: _blue,
        child: Row(children: [
          const _BlueCheck(big: true),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Verified artist', style: _serif(17, FontWeight.w700, Colors.white)),
            Text(names.isEmpty ? 'You carry the blue check.' : 'Vouched for by ${names.join(", ")}', style: const TextStyle(color: _muted, fontSize: 12.5)),
          ])),
        ]),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.child, required this.color, this.margin = EdgeInsets.zero});
  final Widget child;
  final Color color;
  final EdgeInsets margin;
  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0.03)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: child,
      );
}

class _BlueCheck extends StatelessWidget {
  const _BlueCheck({this.big = false});
  final bool big;
  @override
  Widget build(BuildContext context) {
    final s = big ? 30.0 : 18.0;
    return Container(
      width: s, height: s,
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFF58ACFF), Color(0xFF2F6BFF)])),
      alignment: Alignment.center,
      child: Icon(Icons.check_rounded, size: big ? 19 : 12, color: Colors.white),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: const TextStyle(color: _faint, fontSize: 10.5, letterSpacing: 0.8, fontWeight: FontWeight.w700));
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, this.onTap, this.busy = false});
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(gradient: const LinearGradient(colors: [_violet, _violetDeep]), borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: _violet.withValues(alpha: 0.4), blurRadius: 24, offset: const Offset(0, 8))]),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (busy) const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: _bg))),
            Text(label, style: const TextStyle(color: _bg, fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
        ),
      ),
    );
  }
}

class _QuietButton extends StatelessWidget {
  const _QuietButton({required this.label, this.onTap, this.busy = false});
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: _hair)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (busy) const Padding(padding: EdgeInsets.only(right: 9), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ]),
        ),
      ),
    );
  }
}

class _DiagCard extends StatelessWidget {
  const _DiagCard({required this.d});
  final NfcDiagnostics d;
  @override
  Widget build(BuildContext context) {
    if (d.error != null) {
      return _Glow(color: _red, child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: _red, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text('Couldn’t read a tag: ${d.error}', style: const TextStyle(color: _muted, fontSize: 12.5))),
      ]));
    }
    final ok = d.is424;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 82, child: Text(k, style: const TextStyle(color: _faint, fontSize: 11.5))),
            Expanded(child: SelectableText(v, style: const TextStyle(color: _ink, fontSize: 12, fontFamily: 'monospace'))),
          ]),
        );
    return _Glow(
      color: ok ? _green : _amber,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.verified_rounded : Icons.info_outline_rounded, color: ok ? _green : _amber, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(ok ? 'NTAG 424 DNA ✓' : 'Not recognised as NTAG 424 DNA', style: _serif(15.5))),
        ]),
        const SizedBox(height: 4),
        row('model', d.model),
        row('uid', d.uid.isEmpty ? '—' : d.uid),
        row('os type', d.standard.isEmpty ? d.type : '${d.type} · ${d.standard}'),
        if (d.versionHex.isNotEmpty) row('getversion', d.versionHex),
        row('app select', d.appSelected ? 'ok (0x9000)' : 'failed${d.appSelectError != null ? " — ${d.appSelectError}" : ""}'),
        row('content', d.content ?? '(none — blank / not provisioned)'),
      ]),
    );
  }
}

