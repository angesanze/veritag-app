# Veritag mobile app — Flutter app on `veritag_sdk`

A real, designed Flutter app (gallery-dark theme) to see and test the ecosystem
on a phone. Two views:

- **Studio** — the whole loop, on the device: mint an artwork (a fresh artist
  identity in the secure store, registered + provisioned), then *tap* it. The SDM
  CMAC a chip would mirror is computed on-device by the SDK, so you get an
  animated **Authentic / Replayed / Counterfeit** verdict — no chip, no tooling.
- **Verify** — enter a tapped tag's `u`/`c`/`m` and get the verdict.

A connection chip polls the AttestCore endpoint (editable; pre-filled with the
dev machine's LAN IP so the phone reaches it on the same Wi-Fi).

## Build the APK / run it

See **[BUILD.md](BUILD.md)** — `flutter build apk` produces
`build/app/outputs/flutter-apk/app-release.apk` (~48 MB). Or `flutter run` on a
device/emulator. The SDK crypto (identity, SDM-CMAC, EV2) is validated in CI.

```bash
flutter pub get
flutter analyze        # clean
flutter test           # widget smoke + binding conformance
```

## How it's built

- `lib/main.dart` — the UI (theme, Studio + Verify tabs, animated `VerdictCard`,
  connection status). No crypto inline.
- `lib/arttrust_mobile.dart` — logic on the SDK: `studioMint` (enrol + provision,
  no NFC write), `tapAndVerify` (computes the CMAC via `Sdm.computeSdmCmac`),
  `verifyScan`, and the real `mintArtwork` (writes the chip over NFC, EV2 flow).
- Everything — identity, signing, SDM-CMAC, verify — comes from `veritag_sdk`.
  The Veritag binding stays byte-identical to the Python backend and web portal.

On a real phone, set the endpoint to your PC's `http://<LAN-IP>:8080` (the API
must bind `0.0.0.0` — `docker compose up` already publishes it). See
`../../../LOCAL_DEV.md`.
