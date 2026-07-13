/**
 * Curator portal logic.
 *
 * Two layers:
 *  - the ArtTrust DOMAIN client (`ArtTrustApi`) — the curator's real work:
 *    confirm an artist's blue check, see the roster, assemble virtual rooms,
 *    read the same passport a visitor sees. Talks to arttrust-api (Piano C).
 *  - the binding helpers (`arttrustBinding`, `verdictOf`) — kept byte-identical
 *    to the Python backend + Flutter app and pinned by test/portal.test.mjs.
 *
 * No private key is ever created or held here — the curator oversees, the artist
 * signs on their device.
 */
import { type VerifyResult } from "@dna424/client";

export type Verdict = "authentic" | "counterfeit" | "replayed" | "unverified_artist";

/** The curator's policy over the core's three independent booleans. */
export function verdictOf(v: VerifyResult): Verdict {
  if (!v.chip_authentic) return "counterfeit";
  if (!v.not_replayed) return "replayed";
  if (!v.issuer_verified) return "unverified_artist";
  return "authentic";
}

const SEP = 0x1f; // unit separator — must match consumers/arttrust/binding.py

/**
 * The ArtTrust domain binding: SHA-256(uid ‖ 0x1f ‖ title ‖ 0x1f ‖ artist_id).
 * Built by ARTISTS (not the curator); kept here byte-identical to the Python
 * backend and the Flutter app and pinned by test/portal.test.mjs.
 */
export async function arttrustBinding(
  uid: string,
  title: string,
  artistId: string,
): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const parts = [enc.encode(uid), enc.encode(title), enc.encode(artistId)];
  const out: number[] = [];
  parts.forEach((p, i) => {
    if (i > 0) out.push(SEP);
    out.push(...p);
  });
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(out) as BufferSource));
}

// ---- domain types (mirror api/schemas.py) ---------------------------------

export interface Curator {
  curator_id: string;
  name: string;
  bio?: string;
  avatar_url?: string;
}

export interface Artist {
  artist_id: string;
  name: string;
  issuer_id: string;
  verified: boolean;
  verified_by: Curator[];
}

export interface Artwork {
  uid: string;
  title: string;
  artist_id: string;
  binding_id: string;
  description?: string;
  image_data_url?: string;
  video_url?: string;
}

export interface CatalogueEntry {
  artwork: Artwork;
  artist_id: string;
  artist_name: string;
  artist_verified: boolean;
}

export interface ArtworkDetail {
  artwork: Artwork;
  artist: Artist | null;
  exhibitions: ExhibitionRef[];
}

export interface VerificationReq {
  request_id: string;
  artist_id: string;
  curator_id: string;
  status: "pending" | "confirmed" | "rejected" | "expired";
  created_at: number;
  expires_at: number;
  code: string | null;
  artist_name: string | null;
}

export interface ExhibitionItem {
  uid: string;
  caption?: string;
  title?: string | null;
  artist_name?: string | null;
}

export interface Exhibition {
  exhibition_id: string;
  title: string;
  curator_id: string;
  description?: string;
  cover_url?: string;
  starts_at?: string;
  ends_at?: string;
  venue?: string;
  lat?: number | null;
  lng?: number | null;
  items: ExhibitionItem[];
}

export interface ExhibitionRef {
  exhibition_id: string;
  title: string;
  curator_id: string;
  curator_name?: string | null;
  starts_at?: string;
  ends_at?: string;
  venue?: string;
  lat?: number | null;
  lng?: number | null;
}

export interface Passport {
  uid: string;
  ctr: number;
  verdict: Verdict;
  chip_authentic: boolean;
  not_replayed: boolean;
  issuer_verified: boolean;
  issuer_id: string | null;
  reason: string;
  artwork: Artwork | null;
  artist: Artist | null;
  artist_verified: boolean;
  verified_by: Curator[];
  exhibitions: ExhibitionRef[];
}

export interface CreateExhibition {
  curator_id: string;
  title: string;
  description?: string;
  cover_url?: string;
  starts_at?: string;
  ends_at?: string;
  venue?: string;
  lat?: number | null;
  lng?: number | null;
  items: { uid: string; caption?: string }[];
}

export type UpdateExhibition = Partial<Omit<CreateExhibition, "curator_id">>;

export interface CuratorAuth {
  curator_id: string;
  name: string;
  token: string;
}

/** Thin fetch client over arttrust-api (Piano C). Carries the curator session
 *  token (when set) so the guarded endpoints authenticate transparently. */
export class ArtTrustApi {
  constructor(private readonly base: string, private token?: string) {}

  setToken(token?: string) {
    this.token = token;
  }

  private async j<T>(path: string, init?: RequestInit): Promise<T> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.token) headers["Authorization"] = `Bearer ${this.token}`;
    const r = await fetch(`${this.base}${path}`, { ...init, headers: { ...headers, ...(init?.headers as object) } });
    if (!r.ok) {
      let detail = r.statusText;
      try {
        detail = (await r.json()).detail ?? detail;
      } catch {
        /* not json */
      }
      throw new Error(`${r.status} — ${detail}`);
    }
    return (r.status === 204 ? undefined : await r.json()) as T;
  }

  health(): Promise<{ status: string; attest?: string }> {
    return this.j("/healthz");
  }

  // -- auth --
  register(username: string, name: string, password: string, bio = ""): Promise<CuratorAuth> {
    return this.j("/curators", { method: "POST", body: JSON.stringify({ username, name, password, bio }) });
  }
  login(username: string, password: string): Promise<CuratorAuth> {
    return this.j("/curators/login", { method: "POST", body: JSON.stringify({ username, password }) });
  }
  me(): Promise<Curator> {
    return this.j("/curators/me");
  }
  logout(): Promise<unknown> {
    return this.j("/curators/logout", { method: "POST" });
  }

  listCurators(): Promise<Curator[]> {
    return this.j("/curators");
  }
  incoming(curatorId: string, status = "pending"): Promise<VerificationReq[]> {
    return this.j(`/curators/${curatorId}/requests?status=${status}`);
  }
  confirm(requestId: string, code: string): Promise<VerificationReq> {
    return this.j(`/verifications/${requestId}/confirm`, {
      method: "POST",
      body: JSON.stringify({ code }),
    });
  }
  reject(requestId: string): Promise<VerificationReq> {
    return this.j(`/verifications/${requestId}/reject`, { method: "POST" });
  }
  roster(curatorId: string): Promise<Artist[]> {
    return this.j(`/curators/${curatorId}/roster`);
  }
  artistArtworks(artistId: string): Promise<Artwork[]> {
    return this.j(`/artists/${artistId}/artworks`);
  }
  createExhibition(body: CreateExhibition): Promise<Exhibition> {
    return this.j("/exhibitions", { method: "POST", body: JSON.stringify(body) });
  }
  curatorExhibitions(curatorId: string): Promise<Exhibition[]> {
    return this.j(`/curators/${curatorId}/exhibitions`);
  }
  getExhibition(exhibitionId: string): Promise<Exhibition> {
    return this.j(`/exhibitions/${exhibitionId}`);
  }
  updateExhibition(exhibitionId: string, body: UpdateExhibition): Promise<Exhibition> {
    return this.j(`/exhibitions/${exhibitionId}`, { method: "PUT", body: JSON.stringify(body) });
  }
  deleteExhibition(exhibitionId: string): Promise<unknown> {
    return this.j(`/exhibitions/${exhibitionId}`, { method: "DELETE" });
  }
  catalogue(curatorId: string): Promise<CatalogueEntry[]> {
    return this.j(`/curators/${curatorId}/artworks`);
  }
  artworkDetail(uid: string): Promise<ArtworkDetail> {
    return this.j(`/artworks/${uid}`);
  }
  passport(u: string, c: number, m: string, kv = 1): Promise<Passport> {
    const q = new URLSearchParams({ u, c: String(c), m, kv: String(kv) });
    return this.j(`/passport?${q.toString()}`);
  }
  passportUrl(url: string): Promise<Passport> {
    const q = new URL(url).searchParams;
    return this.passport(
      q.get("u") ?? "",
      Number(q.get("c") ?? "0"),
      q.get("m") ?? "",
      Number(q.get("kv") ?? "1"),
    );
  }
}
