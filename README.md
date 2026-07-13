# veritag-app

The Veritag applications — a curator **web portal** and the **mobile app** (Android
APK), both built on [`veritag-sdk`](https://github.com/angesanze/veritag-sdk).

| App | Path | Stack |
|---|---|---|
| Curator portal | `web-portal/` | React + Vite (+ Leaflet maps), talks to the domain API |
| Mobile app | `mobile-app/` | Flutter — artist studio (mint on NTAG 424 DNA) + visitor passport |

## Setup (the `./sdk` convention)

Both apps depend on the SDK via a local path. Clone it once into `./sdk`
(gitignored — CI checks it out the same way):

```bash
git clone git@github.com:angesanze/veritag-sdk.git sdk
```

## Develop

```bash
# web portal (needs Node 20)
cd sdk/ts/dna424-client && npm install && npm run build
cd ../../../web-portal && npm install && npm run dev        # → :5173

# mobile app (needs Flutter 3.38.x + Android SDK)
cd mobile-app
flutter pub get && flutter run                              # or: flutter build apk --release
```

Backend (AttestCore + domain API): lives in the ArtTrust 2.0 monorepo for now —
`docker compose up` there, then point the apps at `http://<LAN-IP>:8090`.

## CI/CD

`.github/workflows/ci.yml` — on every push/PR:
- **web**: SDK build → typecheck → conformance test → Vite bundle (artifact `web-portal`)
- **android**: analyze → test → `flutter build apk --release` (artifact `veritag-apk`)

Push a `v*` tag → **GitHub Release** with the APK and the web bundle attached.

> If `veritag-sdk` is private, add a repo-read PAT as the `SDK_READ_TOKEN` secret
> so CI can check it out; if it's public nothing is needed.
