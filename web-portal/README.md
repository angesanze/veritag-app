# ArtTrust curator portal — web app (React + `@dna424/client`)

The **curator's** web platform — authenticity *oversight*, not an app clone. The
curator does **not** mint tags (that's the artist, on the mobile app, with the
chip). Two views:

- **Verify** — check an artwork's tag (paste the URL it opens, or `u`/`c`/`m`),
  get the verdict, and see the tag **re-attributed to a known artist** from the
  roster. A session audit trail of recent checks builds up.
- **Artists** — the roster: **onboard** an artist by registering their *public*
  key as an issuer (the private key stays on the artist's device; the curator
  keeps only the token), **label** a known issuer id with a name for attribution,
  and **revoke** a compromised artist.

Roles, mirroring the old monolith:
- **Web (this app)** = curator: verify, manage the roster, revoke.
- **Mobile app** = artist (forge/mint tags over NFC) + visitor (check a tag).

## Run

Ships in the stack:
```bash
docker compose up --build      # from the repo root: API :8080 + this portal :5173
open http://localhost:5173
```

Dev with hot-reload:
```bash
cd ../../../sdk/ts/dna424-client && npm install && npm run build   # build the SDK once
cd -
npm install && npm run dev      # http://localhost:5173
npm test                        # binding conformance (tsc + node:test)
```

## Try it end to end

1. An artist makes a tag (simulated): `attestcore/.venv/bin/python
   consumers/arttrust/make_test_tag.py` — prints a verify URL + the `issuer_id`.
2. **Verify** tab → paste the URL → **Authentic** (artist still "unknown").
3. **Artists** tab → *Label a known issuer* → add that `issuer_id` as a name.
4. **Verify** again → now attributed **by that artist**.

The full curator flow (onboard → verify → revoke → unverified) is validated
against a live backend.

## How it's built

- `src/App.tsx` — the React UI (Verify + Artists, roster in `localStorage`).
- `src/portal.ts` — `CuratorClient` on the SDK: `registerArtist`, `revokeArtist`,
  `verify` / `verifyUrl`. No private key is created or held here.
