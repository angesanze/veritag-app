import { useCallback, useEffect, useMemo, useState } from "react";

import {
  ArtTrustApi,
  type Artist,
  type ArtworkDetail,
  type CatalogueEntry,
  type Curator,
  type Exhibition,
  type VerificationReq,
} from "./portal.js";
import { GeoSearch, MapPicker, TrailMap, type TrailStop } from "./map.js";

const BASE_KEY = "arttrust.base";
const TOKEN_KEY = "arttrust.token";
// Baked at build time (Vite): cloud builds point at the deployed domain API.
const DEFAULT_BASE = (import.meta.env.VITE_API_BASE as string | undefined) ?? "http://localhost:8090";

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const minsLeft = (expires: number) => Math.max(0, Math.round((expires * 1000 - Date.now()) / 60000));
const initials = (name: string) => name.trim().split(/\s+/).slice(0, 2).map((w) => w[0] ?? "").join("").toUpperCase();

function Btn(p: { children: React.ReactNode; onClick: () => void; busy?: boolean; disabled?: boolean; variant?: "primary" | "ghost" | "danger"; block?: boolean }) {
  return (
    <button className={`btn ${p.variant ?? "primary"}${p.block ? " block" : ""}`} onClick={p.onClick} disabled={p.disabled || p.busy}>
      {p.busy && <span className="spinner" />}{p.children}
    </button>
  );
}

const BlueCheck = ({ lg }: { lg?: boolean }) => <span className={`bluecheck${lg ? " lg" : ""}`}>✓</span>;

const ROOM_GRADS = [
  "linear-gradient(135deg,#7c5cff,#d8b46a)",
  "linear-gradient(135deg,#2f6bff,#9a82ff)",
  "linear-gradient(135deg,#d8b46a,#ff8a98)",
  "linear-gradient(135deg,#36d399,#2f6bff)",
  "linear-gradient(135deg,#a78bff,#36d399)",
];
const grad = (i: number) => ROOM_GRADS[Math.abs(i) % ROOM_GRADS.length];
const showDates = (a?: string, b?: string) => [a, b].filter(Boolean).join(" – ") || "—";

// ============ AUTH ============
function AuthScreen({ api, base, setBase, onAuthed }: {
  api: ArtTrustApi; base: string; setBase: (s: string) => void; onAuthed: (token: string, c: Curator) => void;
}) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [username, setUsername] = useState("");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showAdv, setShowAdv] = useState(false);

  const submit = async () => {
    setBusy(true); setError("");
    try {
      const auth = mode === "login"
        ? await api.login(username.trim(), password)
        : await api.register(username.trim(), name.trim() || username.trim(), password);
      onAuthed(auth.token, { curator_id: auth.curator_id, name: auth.name } as Curator);
    } catch (e) { setError(errMsg(e)); } finally { setBusy(false); }
  };

  return (
    <div className="auth">
      <div className="auth-brand">
        <div className="auth-brand-inner">
          <div className="brand-mark"><div className="glyph">A</div><b>ArtTrust</b></div>
          <div className="brand-title">Authenticity,<br /><span className="accent">authored</span> by curators.</div>
          <p className="brand-tag">Vouch for the artists you trust, stage exhibitions on the map, and give every artwork a passport a visitor can read with a tap.</p>
          <div className="brand-points">
            <div className="point"><span className="dot">✓</span><div>Grant the <b>blue check</b> with a shared code — proof you met the artist.</div></div>
            <div className="point"><span className="dot">▦</span><div>Stage <b>exhibitions</b> — title, dates, a pin on the map.</div></div>
            <div className="point"><span className="dot">◎</span><div>Every work carries its <b>provenance trail</b> from show to show.</div></div>
          </div>
        </div>
      </div>
      <div className="auth-panel">
        <div className="auth-card">
          <h2>{mode === "login" ? "Welcome back" : "Create your studio"}</h2>
          <p className="sub">{mode === "login" ? "Sign in to your curator account." : "Register as a curator to start vouching."}</p>
          <div className="seg">
            <button className={mode === "login" ? "active" : ""} onClick={() => setMode("login")}>Sign in</button>
            <button className={mode === "register" ? "active" : ""} onClick={() => setMode("register")}>Register</button>
          </div>
          <div className="field"><label className="label">Username</label><input className="input" value={username} onChange={(e) => setUsername(e.target.value)} placeholder="galleria" autoComplete="username" /></div>
          {mode === "register" && (
            <div className="field"><label className="label">Display name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Galleria del Sole" /></div>
          )}
          <div className="field"><label className="label">Password</label><input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" autoComplete={mode === "login" ? "current-password" : "new-password"} onKeyDown={(e) => e.key === "Enter" && submit()} /></div>
          {error && <div className="error">{error}</div>}
          <div style={{ marginTop: 18 }}><Btn block busy={busy} disabled={!username.trim() || !password} onClick={submit}>{mode === "login" ? "Sign in" : "Create account"}</Btn></div>
          <div className="auth-meta">
            Demo logins (seeded): <code>galleria</code> · <code>nord</code> · <code>lumen</code> — password <code>arttrust</code>.
            <br /><a style={{ cursor: "pointer" }} onClick={() => setShowAdv((v) => !v)}>{showAdv ? "Hide" : "Advanced"} · API endpoint</a>
            {showAdv && <input className="input" style={{ marginTop: 8 }} value={base} onChange={(e) => setBase(e.target.value)} />}
          </div>
        </div>
      </div>
    </div>
  );
}

// ============ REQUESTS ============
function RequestsView({ api, curatorId, onChange }: { api: ArtTrustApi; curatorId: string; onChange: () => void }) {
  const [reqs, setReqs] = useState<VerificationReq[]>([]);
  const [codes, setCodes] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [toast, setToast] = useState("");

  const load = useCallback(async () => {
    try { setReqs(await api.incoming(curatorId, "pending")); } catch (e) { setError(errMsg(e)); }
  }, [api, curatorId]);
  useEffect(() => { load(); const id = setInterval(load, 4000); return () => clearInterval(id); }, [load]);

  const confirm = (r: VerificationReq) => async () => {
    setBusy(r.request_id); setError("");
    try { await api.confirm(r.request_id, (codes[r.request_id] ?? "").trim()); setToast(`${r.artist_name ?? "Artist"} verified`); setTimeout(() => setToast(""), 2600); await load(); onChange(); }
    catch (e) { setError(errMsg(e)); } finally { setBusy(""); }
  };
  const reject = (r: VerificationReq) => async () => {
    setBusy(r.request_id); try { await api.reject(r.request_id); await load(); } catch (e) { setError(errMsg(e)); } finally { setBusy(""); }
  };

  return (
    <>
      <div className="card">
        <h3>Pending requests <span className="pill">{reqs.length}</span></h3>
        <p className="sub">An artist asks to be vouched for. Enter the 6-digit code they read to you out-of-band; a match grants their blue check.</p>
        {error && <div className="error">{error}</div>}
        {reqs.length === 0 && <div className="empty">No pending requests.<br />Artists send them from the mobile app.</div>}
        {reqs.map((r) => (
          <div className="req" key={r.request_id}>
            <div className="art"><div className="avatar" style={{ width: 36, height: 36 }}>{initials(r.artist_name ?? "?")}</div><div><b>{r.artist_name ?? r.artist_id}</b><br /><span>wants the blue check</span></div></div>
            <input className="input code-input" inputMode="numeric" maxLength={6} placeholder="••••••" value={codes[r.request_id] ?? ""} onChange={(e) => setCodes({ ...codes, [r.request_id]: e.target.value })} />
            <span className="countdown">expires {minsLeft(r.expires_at)}m</span>
            <div className="req-actions">
              <Btn busy={busy === r.request_id} disabled={(codes[r.request_id] ?? "").length < 6} onClick={confirm(r)}>Confirm</Btn>
              <Btn variant="danger" onClick={reject(r)}>Reject</Btn>
            </div>
          </div>
        ))}
      </div>
      {toast && <div className="toast"><BlueCheck /> {toast}</div>}
    </>
  );
}

// ============ ROSTER (filterable) ============
function RosterView({ api, curatorId, onOpenArtwork }: { api: ArtTrustApi; curatorId: string; onOpenArtwork: (uid: string) => void }) {
  const [roster, setRoster] = useState<Artist[]>([]);
  const [cat, setCat] = useState<CatalogueEntry[]>([]);
  const [q, setQ] = useState("");
  const [onlyWithWorks, setOnlyWithWorks] = useState(false);
  const [open, setOpen] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    Promise.all([api.roster(curatorId), api.catalogue(curatorId)])
      .then(([r, c]) => { setRoster(r); setCat(c); })
      .catch((e) => setError(errMsg(e)));
  }, [api, curatorId]);

  const worksOf = (artistId: string) => cat.filter((c) => c.artist_id === artistId);
  const shown = roster.filter((a) => {
    if (q && !a.name.toLowerCase().includes(q.trim().toLowerCase())) return false;
    if (onlyWithWorks && worksOf(a.artist_id).length === 0) return false;
    return true;
  });

  return (
    <div className="card">
      <h3>Your roster <span className="pill">{shown.length} / {roster.length}</span></h3>
      <p className="sub">Artists you've vouched for. Filter by name, open one to browse their works.</p>
      <div className="filter-row">
        <input className="input" placeholder="Search artists…" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className={`chip${onlyWithWorks ? " on" : ""}`} onClick={() => setOnlyWithWorks((v) => !v)}>With works</button>
      </div>
      {error && <div className="error">{error}</div>}
      {shown.length === 0 && <div className="empty">{roster.length === 0 ? "No verified artists yet — confirm a request to add one." : "No artists match the filter."}</div>}
      {shown.map((a) => {
        const works = worksOf(a.artist_id);
        return (
          <div className="artist-row" key={a.artist_id}>
            <div className="artist-head" onClick={() => setOpen(open === a.artist_id ? "" : a.artist_id)}>
              <div className="av">{initials(a.name)}</div>
              <div className="nm"><b>{a.name} <BlueCheck /></b><span>{a.issuer_id}</span></div>
              <span className="pill">{works.length} works</span>
              <span className="pill">{open === a.artist_id ? "▾" : "▸"}</span>
            </div>
            {open === a.artist_id && (
              <div className="works">
                {works.length === 0 && <div className="hint">No minted artworks yet.</div>}
                {works.map((w, i) => (
                  <div className="work clickable" key={w.artwork.uid} onClick={() => onOpenArtwork(w.artwork.uid)}>
                    {w.artwork.image_data_url
                      ? <img className="sw" src={w.artwork.image_data_url} alt="" />
                      : <div className="sw" style={{ background: grad(i) }} />}
                    <b>{w.artwork.title}</b>
                    <span>{w.artwork.uid}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ============ ARTWORKS (catalogue + passport-style detail) ============
function ArtworksView({ api, curatorId, openUid, setOpenUid }: {
  api: ArtTrustApi; curatorId: string; openUid: string | null; setOpenUid: (u: string | null) => void;
}) {
  const [cat, setCat] = useState<CatalogueEntry[]>([]);
  const [q, setQ] = useState("");
  const [detail, setDetail] = useState<ArtworkDetail | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    api.catalogue(curatorId).then(setCat).catch((e) => setError(errMsg(e)));
  }, [api, curatorId]);

  useEffect(() => {
    if (!openUid) { setDetail(null); return; }
    api.artworkDetail(openUid).then(setDetail).catch((e) => setError(errMsg(e)));
  }, [api, openUid]);

  if (openUid && detail) return <ArtworkDetailView d={detail} onBack={() => setOpenUid(null)} />;

  const shown = cat.filter((c) =>
    !q || c.artwork.title.toLowerCase().includes(q.toLowerCase()) || c.artist_name.toLowerCase().includes(q.toLowerCase()));

  return (
    <div className="card">
      <h3>Catalogue <span className="pill">{shown.length} / {cat.length}</span></h3>
      <p className="sub">Every authenticated work across your roster. Click one to open its record and provenance.</p>
      <div className="filter-row"><input className="input" placeholder="Search by title or artist…" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      {error && <div className="error">{error}</div>}
      {shown.length === 0 && <div className="empty">{cat.length === 0 ? "No works yet — your artists mint them from the app." : "Nothing matches the search."}</div>}
      <div className="frames">
        {shown.map((c, i) => (
          <button className="frame frame-btn" key={c.artwork.uid} onClick={() => setOpenUid(c.artwork.uid)}>
            {c.artwork.image_data_url
              ? <img className="frame-art" src={c.artwork.image_data_url} alt={c.artwork.title} />
              : <div className="frame-art" style={{ background: grad(i) }} />}
            <div className="frame-label">
              <b>{c.artwork.title}</b>
              <span className="frame-artist">{c.artist_name} {c.artist_verified && <BlueCheck />}</span>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}

function ArtworkDetailView({ d, onBack }: { d: ArtworkDetail; onBack: () => void }) {
  const a = d.artwork;
  const stops: TrailStop[] = d.exhibitions
    .filter((e) => e.lat != null && e.lng != null)
    .map((e) => ({ lat: e.lat as number, lng: e.lng as number, title: e.venue || e.title }));
  return (
    <>
      <button className="back" onClick={onBack}>← Catalogue</button>
      <div className="art-detail">
        <div className="art-visual">
          {a.image_data_url
            ? <img src={a.image_data_url} alt={a.title} />
            : <div className="art-placeholder" style={{ background: grad(a.title.length) }} />}
        </div>
        <div className="art-info">
          <div className="eyebrow">CATALOGUE RECORD</div>
          <h2>{a.title}</h2>
          {d.artist && <div className="pp-by">by {d.artist.name}{d.artist.verified && <><BlueCheck /><span className="blue">{d.artist.verified_by?.map((c) => c.name).join(", ")}</span></>}</div>}
          {a.description && <p className="art-desc">{a.description}</p>}
          {a.video_url && <a className="chip" href={a.video_url} target="_blank" rel="noreferrer">▶ Watch video</a>}
          <div className="mono" style={{ marginTop: 14 }}>tag {a.uid}</div>
        </div>
      </div>
      <div className="card">
        <h3>Provenance <span className="pill">{d.exhibitions.length} shows</span></h3>
        <p className="sub">Every exhibition this work has hung in — its life on the map.</p>
        {d.exhibitions.length === 0 ? <div className="empty">Not exhibited yet.</div> : (
          <div className="prov-grid">
            <div className="timeline">
              {d.exhibitions.map((e, i) => (
                <div className="tl" key={e.exhibition_id}>
                  <div className="rail"><div className="node">{i + 1}</div>{i < d.exhibitions.length - 1 && <div className="line" />}</div>
                  <div className="body">
                    <b>{e.title}</b>
                    <div className="m">{showDates(e.starts_at, e.ends_at)}{e.venue ? ` · ${e.venue}` : ""}{e.curator_name ? ` · ${e.curator_name}` : ""}</div>
                  </div>
                </div>
              ))}
            </div>
            {stops.length > 0 && <TrailMap stops={stops} />}
          </div>
        )}
      </div>
    </>
  );
}

// ============ ROOMS (list · dedicated composer · detail) ============
type RoomForm = { title: string; desc: string; start: string; end: string; venue: string; lat: number | null; lng: number | null };
const EMPTY_FORM: RoomForm = { title: "", desc: "", start: "", end: "", venue: "", lat: null, lng: null };
type RoomMode = { kind: "list" } | { kind: "compose"; editing: Exhibition | null } | { kind: "detail"; room: Exhibition };

/** The works picker: a visual wall of the catalogue. Click a card to hang it;
 *  a hung card takes the gold ring and offers its wall label. */
function WorkPicker({ cat, picked, onToggle, onCaption }: {
  cat: CatalogueEntry[];
  picked: Record<string, string>;
  onToggle: (uid: string) => void;
  onCaption: (uid: string, caption: string) => void;
}) {
  const [q, setQ] = useState("");
  const shown = cat.filter((c) =>
    !q || c.artwork.title.toLowerCase().includes(q.toLowerCase()) || c.artist_name.toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <div className="filter-row">
        <input className="input" placeholder="Search your catalogue…" value={q} onChange={(e) => setQ(e.target.value)} />
        <span className="chip on">{Object.keys(picked).length} hung</span>
      </div>
      {cat.length === 0 && <div className="empty">No artworks available yet —<br />your roster mints them from the app.</div>}
      {cat.length > 0 && shown.length === 0 && <div className="empty">Nothing matches the search.</div>}
      <div className="art-picker">
        {shown.map((c, i) => {
          const on = c.artwork.uid in picked;
          return (
            <div key={c.artwork.uid} className={`apick${on ? " on" : ""}`}>
              <button className="apick-hit" onClick={() => onToggle(c.artwork.uid)}>
                {c.artwork.image_data_url
                  ? <img className="apick-art" src={c.artwork.image_data_url} alt={c.artwork.title} />
                  : <div className="apick-art" style={{ background: grad(i) }} />}
                <span className="apick-badge">✓</span>
                <div className="apick-label">
                  <b>{c.artwork.title}</b>
                  <span>{c.artist_name} {c.artist_verified && <BlueCheck />}</span>
                </div>
              </button>
              {on && (
                <input
                  className="input apick-caption"
                  placeholder="Wall label (optional)…"
                  value={picked[c.artwork.uid]}
                  onChange={(e) => onCaption(c.artwork.uid, e.target.value)}
                />
              )}
            </div>
          );
        })}
      </div>
    </>
  );
}

function RoomsView({ api, curatorId }: { api: ArtTrustApi; curatorId: string }) {
  const [rooms, setRooms] = useState<Exhibition[]>([]);
  const [cat, setCat] = useState<CatalogueEntry[]>([]);
  const [picked, setPicked] = useState<Record<string, string>>({});
  const [form, setForm] = useState<RoomForm>(EMPTY_FORM);
  const [mode, setMode] = useState<RoomMode>({ kind: "list" });
  const [busy, setBusy] = useState(false);
  const [confirmDel, setConfirmDel] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try {
      setRooms(await api.curatorExhibitions(curatorId));
      setCat(await api.catalogue(curatorId));
    } catch (e) { setError(errMsg(e)); }
  }, [api, curatorId]);
  useEffect(() => { load(); }, [load]);

  const set = (patch: Partial<RoomForm>) => setForm((f) => ({ ...f, ...patch }));
  const togglePick = (uid: string) => setPicked((p) => { const n = { ...p }; if (uid in n) delete n[uid]; else n[uid] = ""; return n; });
  const setCaption = (uid: string, caption: string) => setPicked((p) => ({ ...p, [uid]: caption }));

  const startCreate = () => {
    setForm(EMPTY_FORM); setPicked({}); setError("");
    setMode({ kind: "compose", editing: null });
    window.scrollTo({ top: 0, behavior: "smooth" });
  };
  const startEdit = (room: Exhibition) => {
    setForm({ title: room.title, desc: room.description ?? "", start: room.starts_at ?? "", end: room.ends_at ?? "", venue: room.venue ?? "", lat: room.lat ?? null, lng: room.lng ?? null });
    setPicked(Object.fromEntries(room.items.map((i) => [i.uid, i.caption ?? ""])));
    setError("");
    setMode({ kind: "compose", editing: room });
    window.scrollTo({ top: 0, behavior: "smooth" });
  };
  const toList = () => { setMode({ kind: "list" }); setError(""); };

  const save = async () => {
    const editing = mode.kind === "compose" ? mode.editing : null;
    setBusy(true); setError("");
    const body = {
      title: form.title.trim(), description: form.desc.trim(),
      starts_at: form.start.trim(), ends_at: form.end.trim(),
      venue: form.venue.trim(), lat: form.lat, lng: form.lng,
      items: Object.entries(picked).map(([uid, caption]) => ({ uid, caption })),
    };
    try {
      if (editing) await api.updateExhibition(editing.exhibition_id, body);
      else await api.createExhibition({ curator_id: curatorId, ...body });
      await load(); toList();
    } catch (e) { setError(errMsg(e)); } finally { setBusy(false); }
  };

  const remove = async (room: Exhibition) => {
    if (!confirmDel) { setConfirmDel(true); setTimeout(() => setConfirmDel(false), 3500); return; }
    try { await api.deleteExhibition(room.exhibition_id); setConfirmDel(false); await load(); toList(); }
    catch (e) { setError(errMsg(e)); }
  };

  const openRoom = async (id: string) => {
    try { setMode({ kind: "detail", room: await api.getExhibition(id) }); } catch (e) { setError(errMsg(e)); }
  };

  // ---- compose (its own page) ----
  if (mode.kind === "compose") {
    const editing = mode.editing;
    return (
      <>
        <button className="back" onClick={toList}>← Exhibitions</button>
        <div className="composer">
          <div className="card composer-left">
            <h3>{editing ? "Edit the show" : "The show"}</h3>
            <p className="sub">{editing ? `Editing “${editing.title}”.` : "Title, dates, and a place on the map."}</p>
            <div className="field"><label className="label">Title</label><input className="input" value={form.title} onChange={(e) => set({ title: e.target.value })} placeholder="Der Blaue Reiter" /></div>
            <div className="field"><label className="label">Venue</label><input className="input" value={form.venue} onChange={(e) => set({ venue: e.target.value })} placeholder="Galerie Thannhauser, München" /></div>
            <div className="grid-2">
              <div className="field"><label className="label">Opens</label><input className="input" value={form.start} onChange={(e) => set({ start: e.target.value })} placeholder="1911-12-18" /></div>
              <div className="field"><label className="label">Closes</label><input className="input" value={form.end} onChange={(e) => set({ end: e.target.value })} placeholder="1912-01-01" /></div>
            </div>
            <div className="field"><label className="label">Description</label><textarea className="input" rows={3} value={form.desc} onChange={(e) => set({ desc: e.target.value })} placeholder="A short blurb for the room" /></div>
            <label className="label">Place on the map <span className="hint-inline">search, or click to drop the pin</span></label>
            <GeoSearch onPick={(r) => {
              set({ lat: r.lat, lng: r.lng, ...(form.venue.trim() ? {} : { venue: r.label.split(", ").slice(0, 2).join(", ") }) });
            }} />
            <MapPicker lat={form.lat} lng={form.lng} onPick={(lat, lng) => set({ lat, lng })} />
            <div className="grid-2" style={{ marginTop: 10 }}>
              <div className="field"><label className="label">Latitude</label><input className="input" value={form.lat ?? ""} onChange={(e) => set({ lat: e.target.value === "" ? null : Number(e.target.value) })} placeholder="48.1405" /></div>
              <div className="field"><label className="label">Longitude</label><input className="input" value={form.lng ?? ""} onChange={(e) => set({ lng: e.target.value === "" ? null : Number(e.target.value) })} placeholder="11.5716" /></div>
            </div>
          </div>
          <div className="card composer-right">
            <h3>Hang the works</h3>
            <p className="sub">Click a work to hang it in this show; add a wall label if you like.</p>
            <WorkPicker cat={cat} picked={picked} onToggle={togglePick} onCaption={setCaption} />
          </div>
        </div>
        <div className="composer-actions">
          <Btn busy={busy} disabled={!form.title.trim() || Object.keys(picked).length === 0} onClick={save}>{editing ? "Save changes" : "Create exhibition"}</Btn>
          <Btn variant="ghost" onClick={toList}>Cancel</Btn>
          {error && <div className="error" style={{ marginTop: 0 }}>{error}</div>}
        </div>
      </>
    );
  }

  // ---- detail ----
  if (mode.kind === "detail") {
    const room = mode.room;
    return (
      <>
        <button className="back" onClick={toList}>← All exhibitions</button>
        <div className="room-hero">
          <div className="room-hero-cover" style={{ background: grad(room.title.length) }} />
          <div className="room-hero-body">
            <div className="hero-top">
              <div>
                <div className="eyebrow">EXHIBITION</div>
                <h2>{room.title}</h2>
                <div className="room-hero-meta">
                  <span>{showDates(room.starts_at, room.ends_at)}</span>
                  {room.venue && <><span className="dot-sep" /><span>{room.venue}</span></>}
                  <span className="dot-sep" /><span>{room.items.length} works</span>
                </div>
              </div>
              <div className="hero-actions">
                <Btn variant="ghost" onClick={() => startEdit(room)}>Edit</Btn>
                <Btn variant="danger" onClick={() => remove(room)}>{confirmDel ? "Confirm delete?" : "Delete"}</Btn>
              </div>
            </div>
            {room.description && <p className="room-hero-desc">{room.description}</p>}
          </div>
        </div>
        {room.lat != null && room.lng != null && (
          <div className="card"><h3>Location</h3><p className="sub">{room.venue || "Pinned on the map."}</p>
            <TrailMap stops={[{ lat: room.lat, lng: room.lng, title: room.venue || room.title }]} /></div>
        )}
        <div className="card">
          <h3>In this room <span className="pill">{room.items.length}</span></h3>
          {room.items.length === 0 ? <div className="empty">No works placed yet.</div> : (
            <div className="frames">
              {room.items.map((it, i) => (
                <div className="frame" key={it.uid}>
                  <div className="frame-art" style={{ background: grad(i + 2) }} />
                  <div className="frame-label">
                    <b>{it.title ?? "Untitled"}</b>
                    {it.artist_name && <span className="frame-artist">{it.artist_name}</span>}
                    {it.caption && <em>{it.caption}</em>}
                    <code>{it.uid}</code>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
        {error && <div className="error">{error}</div>}
      </>
    );
  }

  // ---- list (the tab's home) ----
  return (
    <div className="card">
      <div className="list-head">
        <div>
          <h3>Your exhibitions <span className="pill">{rooms.length}</span></h3>
          <p className="sub" style={{ margin: 0 }}>Click one to walk through it, edit it, or take it down.</p>
        </div>
        <Btn onClick={startCreate}>＋ New exhibition</Btn>
      </div>
      {error && <div className="error">{error}</div>}
      {rooms.length === 0 ? (
        <div className="empty">No exhibitions yet.<br />Stage the first one — it becomes your artworks' provenance.</div>
      ) : (
        <div className="room-grid" style={{ marginTop: 18 }}>
          {rooms.map((r, i) => (
            <button className="room-card" key={r.exhibition_id} onClick={() => openRoom(r.exhibition_id)}>
              <div className="room-cover" style={{ background: grad(i) }}><span className="room-count">{r.items.length}</span></div>
              <div className="room-body">
                <b>{r.title}</b>
                <div className="meta"><span>{r.starts_at || "—"}</span>{r.venue && <><span className="dot-sep" />{r.venue}</>}</div>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// ============ DASHBOARD ============
type Tab = "requests" | "roster" | "artworks" | "rooms";
const NAV: { key: Tab; ic: string; label: string }[] = [
  { key: "requests", ic: "✉", label: "Requests" },
  { key: "roster", ic: "❖", label: "Roster" },
  { key: "artworks", ic: "▣", label: "Artworks" },
  { key: "rooms", ic: "▦", label: "Exhibitions" },
];

function Dashboard({ api, session, online, onLogout }: { api: ArtTrustApi; session: Curator; online: boolean | null; onLogout: () => void }) {
  const [tab, setTab] = useState<Tab>("requests");
  const [pending, setPending] = useState(0);
  const [openUid, setOpenUid] = useState<string | null>(null);

  const refreshPending = useCallback(async () => {
    try { setPending((await api.incoming(session.curator_id, "pending")).length); } catch { /* ignore */ }
  }, [api, session.curator_id]);
  useEffect(() => { refreshPending(); const id = setInterval(refreshPending, 4000); return () => clearInterval(id); }, [refreshPending]);

  const head: Record<Tab, { t: string; s: string }> = {
    requests: { t: "Verification requests", s: "Grant the blue check to artists who prove their identity with the shared code." },
    roster: { t: "Your roster", s: "The artists you vouch for — searchable, with every work they've authenticated." },
    artworks: { t: "Catalogue", s: "Browse the works across your roster; open one to read its record and provenance." },
    rooms: { t: "Exhibitions", s: "Stage shows with a place on the map — they become each artwork's provenance." },
  };

  const openArtwork = (uid: string) => { setOpenUid(uid); setTab("artworks"); };

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="side-brand"><div className="glyph">A</div><b>ArtTrust</b></div>
        <div className="side-curator"><div className="avatar">{initials(session.name)}</div><div className="who"><b>{session.name}</b><span>curator</span></div></div>
        <nav className="nav">
          {NAV.map((n) => (
            <button key={n.key} className={`nav-item${tab === n.key ? " active" : ""}`} onClick={() => { setTab(n.key); if (n.key !== "artworks") setOpenUid(null); }}>
              <span className="ic">{n.ic}</span>{n.label}
              {n.key === "requests" && pending > 0 && <span className="count">{pending}</span>}
            </button>
          ))}
        </nav>
        <div className="side-spacer" />
        <div className="side-bottom">
          <div className="status-row"><span className={`dot ${online === null ? "" : online ? "ok" : "bad"}`} />{online === null ? "checking…" : online ? "Connected" : "Offline"}</div>
          <Btn variant="ghost" block onClick={onLogout}>Sign out</Btn>
        </div>
      </aside>
      <main className="main">
        <div className="page-head"><h1>{head[tab].t}</h1><p>{head[tab].s}</p></div>
        {tab === "requests" && <RequestsView api={api} curatorId={session.curator_id} onChange={refreshPending} />}
        {tab === "roster" && <RosterView api={api} curatorId={session.curator_id} onOpenArtwork={openArtwork} />}
        {tab === "artworks" && <ArtworksView api={api} curatorId={session.curator_id} openUid={openUid} setOpenUid={setOpenUid} />}
        {tab === "rooms" && <RoomsView api={api} curatorId={session.curator_id} />}
      </main>
    </div>
  );
}

// ============ APP ============
export function App() {
  const [base, setBase] = useState(() => localStorage.getItem(BASE_KEY) ?? DEFAULT_BASE);
  const [token, setToken] = useState<string | null>(() => localStorage.getItem(TOKEN_KEY));
  const [session, setSession] = useState<Curator | null>(null);
  const [online, setOnline] = useState<boolean | null>(null);
  const [restoring, setRestoring] = useState(true);

  const api = useMemo(() => new ArtTrustApi(base, token ?? undefined), [base, token]);
  useEffect(() => { localStorage.setItem(BASE_KEY, base); }, [base]);

  useEffect(() => {
    let alive = true;
    const ping = async () => { try { await api.health(); if (alive) setOnline(true); } catch { if (alive) setOnline(false); } };
    ping(); const id = setInterval(ping, 5000); return () => { alive = false; clearInterval(id); };
  }, [api]);

  useEffect(() => {
    let alive = true;
    (async () => {
      if (!token) { setSession(null); setRestoring(false); return; }
      try { const me = await api.me(); if (alive) setSession(me); }
      catch { if (alive) { setSession(null); setToken(null); localStorage.removeItem(TOKEN_KEY); } }
      finally { if (alive) setRestoring(false); }
    })();
    return () => { alive = false; };
  }, [api, token]);

  const onAuthed = (t: string, c: Curator) => { localStorage.setItem(TOKEN_KEY, t); setToken(t); setSession(c); };
  const onLogout = () => { api.logout().catch(() => {}); localStorage.removeItem(TOKEN_KEY); setToken(null); setSession(null); };

  if (token && restoring) return <div className="auth"><div className="auth-panel"><div className="hint">Restoring session…</div></div></div>;
  if (!session) return <AuthScreen api={api} base={base} setBase={setBase} onAuthed={onAuthed} />;
  return <Dashboard api={api} session={session} online={online} onLogout={onLogout} />;
}
