/**
 * Leaflet wrappers, styled to the portal's dark gallery aesthetic.
 *
 *  - GeoSearch : find a place by name (Nominatim/OSM) and drop the pin there
 *  - MapPicker : click to drop the show's pin (create/edit a room)
 *  - TrailMap  : an artwork's provenance — numbered stops, chained in order
 *
 * Tiles and geocoding come from OpenStreetMap (network required); the numeric
 * lat/lng fields next to the picker keep the flow usable offline.
 */
import { useEffect, useRef, useState } from "react";
import * as L from "leaflet";
import "leaflet/dist/leaflet.css";

const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const ATTRIB = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';
const DEFAULT_CENTER: L.LatLngTuple = [45.4642, 9.19]; // Milano

function makeMap(el: HTMLElement, center: L.LatLngTuple, zoom: number): L.Map {
  const map = L.map(el, { center, zoom, zoomControl: true, attributionControl: true });
  L.tileLayer(TILES, { attribution: ATTRIB, maxZoom: 19 }).addTo(map);
  return map;
}

const pin = (label?: string) =>
  L.divIcon({
    className: "pin-wrap",
    html: `<span class="pin">${label ?? ""}</span>`,
    iconSize: [26, 26],
    iconAnchor: [13, 13],
  });

export function MapPicker({ lat, lng, onPick }: {
  lat: number | null;
  lng: number | null;
  onPick: (lat: number, lng: number) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const marker = useRef<L.Marker | null>(null);
  const pickRef = useRef(onPick);
  pickRef.current = onPick;

  useEffect(() => {
    if (!el.current || map.current) return;
    const m = makeMap(el.current, lat != null && lng != null ? [lat, lng] : DEFAULT_CENTER, lat != null ? 13 : 5);
    m.on("click", (e: L.LeafletMouseEvent) => {
      pickRef.current(Number(e.latlng.lat.toFixed(6)), Number(e.latlng.lng.toFixed(6)));
    });
    map.current = m;
    return () => { m.remove(); map.current = null; marker.current = null; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const m = map.current;
    if (!m) return;
    if (lat == null || lng == null) {
      marker.current?.remove();
      marker.current = null;
      return;
    }
    const isNew = !marker.current;
    if (isNew) {
      marker.current = L.marker([lat, lng], { icon: pin() }).addTo(m);
    } else {
      marker.current!.setLatLng([lat, lng]);
    }
    // A far jump (a search result) flies in close; a nearby nudge (a map click)
    // just keeps the pin in view.
    const far = m.getCenter().distanceTo([lat, lng]) > 50_000;
    if (far || (isNew && m.getZoom() < 12)) m.flyTo([lat, lng], 14, { duration: 0.8 });
    else m.panTo([lat, lng]);
  }, [lat, lng]);

  return <div className="map map-picker" ref={el} />;
}

interface GeoResult {
  lat: number;
  lng: number;
  label: string;
}

/** Place search over Nominatim (OSM). Enter or the button searches; picking a
 *  result drops the pin (and hands the parent a human-readable label). */
export function GeoSearch({ onPick }: { onPick: (r: GeoResult) => void }) {
  const [q, setQ] = useState("");
  const [results, setResults] = useState<GeoResult[]>([]);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");

  const search = async () => {
    const query = q.trim();
    if (!query) return;
    setBusy(true); setError(""); setOpen(false);
    try {
      const url = `https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=${encodeURIComponent(query)}`;
      const r = await fetch(url, { headers: { Accept: "application/json" } });
      if (!r.ok) throw new Error(`geocoder: ${r.status}`);
      const rows = (await r.json()) as Array<{ lat: string; lon: string; display_name: string }>;
      const found = rows.map((x) => ({ lat: Number(x.lat), lng: Number(x.lon), label: x.display_name }));
      setResults(found);
      setOpen(true);
      if (found.length === 0) setError("No places found — try a broader name.");
    } catch {
      setError("Search unavailable (offline?) — click the map or type lat/lng.");
    } finally {
      setBusy(false);
    }
  };

  const pickResult = (res: GeoResult) => {
    setOpen(false);
    setQ(res.label.split(",").slice(0, 2).join(","));
    onPick(res);
  };

  return (
    <div className="geo">
      <div className="geo-row">
        <input
          className="input"
          placeholder="Search a place — museum, gallery, city…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && search()}
        />
        <button className="btn ghost geo-btn" onClick={search} disabled={busy || !q.trim()}>
          {busy ? <span className="spinner" /> : "⌕"} Search
        </button>
      </div>
      {error && <div className="geo-error">{error}</div>}
      {open && results.length > 0 && (
        <div className="geo-results">
          {results.map((res, i) => {
            const [head, ...rest] = res.label.split(", ");
            return (
              <button key={i} className="geo-hit" onClick={() => pickResult(res)}>
                <b>{head}</b>
                <span>{rest.slice(0, 4).join(", ")}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

export interface TrailStop {
  lat: number;
  lng: number;
  title: string;
}

export function TrailMap({ stops }: { stops: TrailStop[] }) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);

  useEffect(() => {
    if (!el.current || stops.length === 0) return;
    const m = makeMap(el.current, [stops[0].lat, stops[0].lng], 6);
    const pts: L.LatLngTuple[] = stops.map((s) => [s.lat, s.lng]);
    if (pts.length > 1) {
      L.polyline(pts, { color: "#d8b46a", weight: 2, opacity: 0.75, dashArray: "6 8" }).addTo(m);
    }
    stops.forEach((s, i) => {
      L.marker([s.lat, s.lng], { icon: pin(String(i + 1)) }).addTo(m).bindTooltip(s.title);
    });
    m.fitBounds(L.latLngBounds(pts).pad(0.35), { maxZoom: 12 });
    map.current = m;
    return () => { m.remove(); map.current = null; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(stops)]);

  if (stops.length === 0) return null;
  return <div className="map map-trail" ref={el} />;
}
