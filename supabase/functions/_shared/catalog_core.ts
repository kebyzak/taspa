export type Json = Record<string, unknown>;
type Kind = "movie" | "show";
type Browse = "trending" | "popular" | "new" | "upcoming";
export type RequestSpec =
  | { operation: "trending"; kind: Kind; page: number; shelf: Browse; genre?: number }
  | { operation: "search"; query: string; page: number }
  | { operation: "person"; tmdb_id: number }
  | { operation: "hydrate"; kind: Kind; tmdb_id: number }
  | { operation: "hydrate_season"; tmdb_id: number; season_number: number };

export class CatalogError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: string) {
    super(code);
  }
}

export function object(value: unknown): Json {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Json : {};
}

export function parse(value: unknown): RequestSpec {
  const input = object(value);
  const kind = input.kind;
  if (input.operation === "person" && typeof input.tmdb_id === "number" &&
      Number.isSafeInteger(input.tmdb_id) && input.tmdb_id > 0) {
    return { operation: "person", tmdb_id: input.tmdb_id };
  }
  if (input.operation === "hydrate_season" &&
      typeof input.tmdb_id === "number" && Number.isSafeInteger(input.tmdb_id) && input.tmdb_id > 0 &&
      typeof input.season_number === "number" && Number.isInteger(input.season_number) &&
      input.season_number >= 0 && input.season_number <= 10000) {
    return { operation: "hydrate_season", tmdb_id: input.tmdb_id, season_number: input.season_number };
  }
  if (input.operation === "hydrate" && (kind === "movie" || kind === "show") &&
      typeof input.tmdb_id === "number" && Number.isSafeInteger(input.tmdb_id) && input.tmdb_id > 0) {
    return { operation: "hydrate", kind, tmdb_id: input.tmdb_id };
  }
  const page = input.page ?? 1;
  if (typeof page !== "number" || !Number.isInteger(page) || page < 1 || page > 10) {
    throw new CatalogError(400, "invalid_page");
  }
  if (input.operation === "trending" && (kind === "movie" || kind === "show")) {
    const shelf = (input.shelf ?? "trending") as Browse;
    if (!["trending","popular","new","upcoming"].includes(shelf)) throw new CatalogError(400, "invalid_shelf");
    const genre = input.genre;
    if (genre !== undefined && (typeof genre !== "number" || !Number.isInteger(genre) || genre < 1 || genre > 99999)) {
      throw new CatalogError(400, "invalid_genre");
    }
    return { operation: "trending", kind, page, shelf, ...(typeof genre === "number" ? { genre } : {}) };
  }
  const query = typeof input.query === "string" ? input.query.trim().replace(/\s+/g, " ") : "";
  if (input.operation === "search" && query.length >= 2 && query.length <= 100) {
    return { operation: "search", query, page };
  }
  throw new CatalogError(400, "invalid_catalog_request");
}

export function defaultKey(keys: string, current: string, legacy: string): string | undefined {
  const configured = Deno.env.get(keys);
  if (configured) {
    const key = object(JSON.parse(configured)).default;
    if (typeof key === "string" && key) return key;
  }
  return Deno.env.get(current) ?? Deno.env.get(legacy);
}

export async function sha(value: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function text(value: unknown, max: number): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null;
}

function image(value: unknown): string | null {
  return typeof value === "string" && /^\/[A-Za-z0-9_.-]+\.(jpg|png|webp)$/.test(value) ? value : null;
}

function releaseDay(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(value);
  return Number.isFinite(date.valueOf()) && date.toISOString().startsWith(value) ? value : null;
}

function number(value: unknown, min: number, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) {
    throw new CatalogError(502, "invalid_upstream");
  }
  return value;
}

function children(source: unknown, type: "season" | "episode"): Json[] {
  if (!Array.isArray(source) || source.length === 0 || source.length > (type === "season" ? 120 : 1200)) {
    throw new CatalogError(502, "missing_children");
  }
  // One malformed row (missing id or number, as some long anime have) is skipped instead of failing the whole show.
  const rows = source.flatMap((value) => {
    const row = object(value);
    const id = row.id;
    const ordinal = row[type === "season" ? "season_number" : "episode_number"];
    if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 1 ||
        typeof ordinal !== "number" || !Number.isSafeInteger(ordinal) || ordinal < (type === "season" ? 0 : 1)) return [];
    const display_title = text(row.name, 300) ?? (type === "season" ? `Season ${ordinal}` : `Episode ${ordinal}`);
    const count = row.episode_count;
    return [type === "season"
      ? { tmdb_id: id, display_title, season_number: ordinal,
          expected_episodes: typeof count === "number" && Number.isSafeInteger(count) && count >= 0 ? count : 0,
          first_release_day: releaseDay(row.air_date) }
      : { tmdb_id: id, display_title, episode_number: ordinal, release_day: releaseDay(row.air_date),
          runtime_minutes: typeof row.runtime === "number" && Number.isInteger(row.runtime) && row.runtime > 0 && row.runtime < 32768 ? row.runtime : null }];
  });
  if (rows.length === 0) throw new CatalogError(502, "missing_children");
  return rows;
}

function normalize(value: unknown, kind: Kind): Json | null {
  const row = object(value);
  const isMovie = kind === "movie";
  const label = text(isMovie ? row.title : row.name, 300);
  if (row.adult === true || !label || typeof row.id !== "number" ||
      !Number.isSafeInteger(row.id) || row.id <= 0) return null;
  const date = isMovie ? row.release_date : row.first_air_date;
  const runtime = isMovie ? row.runtime : Array.isArray(row.episode_run_time) ? row.episode_run_time[0] : null;
  return {
    kind,
    tmdb_id: row.id,
    display_title: label,
    original_title: text(isMovie ? row.original_title : row.original_name, 300),
    overview: text(row.overview, 4000),
    poster_path: image(row.poster_path),
    backdrop_path: image(row.backdrop_path),
    first_release_day: releaseDay(date),
    runtime_minutes: typeof runtime === "number" && Number.isInteger(runtime) && runtime > 0 && runtime <= 32767 ? runtime : null,
    source_release_status: text(row.status, 80),
  };
}

function person(value: unknown): Json | null {
  const row = object(value);
  const name = text(row.name, 300);
  if (row.adult === true || !name || typeof row.id !== "number" || !Number.isSafeInteger(row.id) || row.id <= 0) return null;
  return { tmdb_id: row.id, name, department: text(row.known_for_department, 80), portrait: image(row.profile_path) };
}

function details(row: Json): Json {
  const credits = object(row.credits);
  const cast = Array.isArray(credits.cast) ? credits.cast.slice(0, 12).flatMap((x) => {
    const actor = person(x);
    return actor ? [{ ...actor, role: text(object(x).character, 100) }] : [];
  }) : [];
  const crew = (Array.isArray(row.created_by) ? row.created_by : Array.isArray(credits.crew) ?
    credits.crew.filter((x) => object(x).job === "Director") : []).slice(0, 5).flatMap((x) => {
      const director = person(x);
      return director ? [director] : [];
    });
  const videos = object(row.videos).results;
  const trailer = Array.isArray(videos) ? videos.map(object).find((v) =>
    v.site === "YouTube" && v.type === "Trailer" && typeof v.key === "string" && /^[\w-]{11}$/.test(v.key)) : null;
  const kind: Kind = typeof row.title === "string" ? "movie" : "show";
  const similar = object(row.similar).results;
  return {
    cast, creators: crew, trailer: trailer?.key ?? null,
    similar: Array.isArray(similar) ? similar.slice(0, 10).flatMap((v) => {
      const title = normalize(v, kind);
      return title ? [title] : [];
    }) : [],
  };
}

function regionalReleases(row: Json): Json[] | undefined {
  const regions = object(row.release_dates).results;
  if (!Array.isArray(regions)) return undefined;
  return regions.flatMap((value) => {
    const region = object(value);
    if (typeof region.iso_3166_1 !== "string" || !/^[A-Z]{2}$/.test(region.iso_3166_1) ||
      !Array.isArray(region.release_dates)) return [];
    return region.release_dates.flatMap((value) => {
      const release = object(value);
      const release_day = releaseDay(typeof release.release_date === "string" ? release.release_date.slice(0, 10) : null);
      return release_day && [2,3,4].includes(release.type as number) ?
        [{ market: region.iso_3166_1, release_kind: release.type, release_day }] : [];
    });
  });
}

// Title rating shown in place of the community score: IMDb via OMDb when available, else TMDB.
// OMDb is optional (no OMDB_API_KEY → TMDB only) and its failures never fail the hydrate.
async function externalRating(row: Json): Promise<Json | null> {
  const imdbId = text(row.imdb_id, 20) ?? text(object(row.external_ids).imdb_id, 20);
  const validId = imdbId && /^tt\d{5,10}$/.test(imdbId) ? imdbId : null;
  const key = Deno.env.get("OMDB_API_KEY");
  if (validId && key) {
    try {
      const url = new URL("https://www.omdbapi.com/");
      url.searchParams.set("i", validId);
      url.searchParams.set("apikey", key);
      const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
      if (response.ok) {
        const data = await body(response);
        const value = Number(data.imdbRating);
        const votes = Number(String(data.imdbVotes ?? "").replace(/,/g, ""));
        if (data.Response === "True" && Number.isFinite(value) && value > 0 && value <= 10) {
          const ratings: Json[] = Array.isArray(data.Ratings) ? data.Ratings : [];
          const tomato = parseInt(String(ratings.find((r) => r?.Source === "Rotten Tomatoes")?.Value ?? ""), 10);
          return {
            source: "imdb",
            value,
            votes: Number.isSafeInteger(votes) ? votes : null,
            imdb_id: validId,
            rotten: tomato >= 0 && tomato <= 100 ? tomato : null,
          };
        }
      }
    } catch {
      // Fall through to the TMDB score.
    }
  }
  const average = typeof row.vote_average === "number" ? row.vote_average : 0;
  const count = typeof row.vote_count === "number" ? row.vote_count : 0;
  // Below ~20 votes the TMDB average is noise, so show nothing rather than a misleading number.
  if (average > 0 && average <= 10 && count >= 20) {
    return { source: "tmdb", value: Math.round(average * 10) / 10, votes: count, imdb_id: validId };
  }
  return null;
}

export async function body(response: Response): Promise<Json> {
  const raw = await response.text();
  // Long anime seasons (Boruto: ~300 episodes with cast and crew) exceed 1.5 MB, so allow up to 8 MB.
  if (raw.length > 8_000_000) throw new CatalogError(502, "invalid_upstream");
  return object(JSON.parse(raw));
}

export type CatalogResult = { data: unknown; fetched_at: unknown; stale: boolean };

/**
 * Cache-first catalog operation shared by the catalog and must-import functions: claims the cache lease,
 * calls TMDB when the entry is stale, and stores titles, seasons and episodes. `actor` keys the per-caller budget.
 */
export async function runCatalog(spec: RequestSpec, actor: string): Promise<CatalogResult> {
    const base = Deno.env.get("SUPABASE_URL");
    const service = defaultKey("SUPABASE_SECRET_KEYS", "SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY");
    if (!base || !service) throw new CatalogError(503, "catalog_unconfigured");
    const key = await sha(`v3:en-US:${JSON.stringify(spec)}`);

    const rpc = async (name: string, values: Json): Promise<Json> => {
      const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: {
          apikey: service,
          ...(!service.startsWith("sb_secret_") ? { Authorization: `Bearer ${service}` } : {}),
          "Content-Type": "application/json",
          "Content-Profile": "api",
        },
        body: JSON.stringify(values),
        signal: AbortSignal.timeout(4500),
      });
      const result = await body(response);
      if (!response.ok) {
        if (result.message === "unavailable") throw new CatalogError(404, "unavailable");
        throw new CatalogError(503, "catalog_storage_unavailable");
      }
      return result;
    };
    const claim = await rpc("catalog_claim", { request_key: key, requester: await sha(actor) });
    const cached = (): CatalogResult => ({ data: claim.value, fetched_at: claim.fetched_at, stale: claim.state !== "fresh" });
    if (claim.state === "fresh") return cached();
    if (claim.state !== "leased" || typeof claim.lease !== "string") {
      if (claim.value) return cached();
      throw new CatalogError(429, "catalog_busy", "15");
    }

    const token = Deno.env.get("TMDB_READ_ACCESS_TOKEN");
    if (!token) {
      if (claim.value) return cached();
      throw new CatalogError(503, "catalog_unconfigured");
    }
    const kindPath = (kind: Kind) => kind === "show" ? "tv" : "movie";
    const path = spec.operation === "search" ? "search/multi" :
      spec.operation === "person" ? `person/${spec.tmdb_id}` :
      spec.operation === "hydrate_season" ? `tv/${spec.tmdb_id}/season/${spec.season_number}` :
      spec.operation === "hydrate" ? `${kindPath(spec.kind)}/${spec.tmdb_id}` :
      spec.shelf === "trending" && !spec.genre ? `trending/${kindPath(spec.kind)}/week` : `discover/${kindPath(spec.kind)}`;
    const url = new URL(`https://api.themoviedb.org/3/${path}`);
    url.searchParams.set("language", "en-US");
    if (spec.operation === "search" || spec.operation === "trending") url.searchParams.set("page", String(spec.page));
    if (spec.operation === "search") {
      url.searchParams.set("query", spec.query);
      url.searchParams.set("include_adult", "false");
    }
    if (spec.operation === "hydrate") {
      // Shows carry imdb_id only in external_ids; movies have it at the top level.
      url.searchParams.set("append_to_response", `credits,videos,similar${spec.kind === "movie" ? ",release_dates" : ",external_ids"}`);
    }
    if (spec.operation === "person") url.searchParams.set("append_to_response", "combined_credits");
    if (spec.operation === "trending" && (spec.shelf !== "trending" || spec.genre)) {
      const day = (offset: number) => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10);
      const date = spec.kind === "movie" ? "primary_release_date" : "first_air_date";
      // Upcoming is "most anticipated in the next 90 days": by date it led with obscure titles that have no poster yet.
      url.searchParams.set("sort_by", "popularity.desc");
      url.searchParams.set("include_adult", "false");
      if (spec.genre) url.searchParams.set("with_genres", String(spec.genre));
      if (spec.shelf === "new" || spec.shelf === "upcoming") {
        url.searchParams.set(`${date}.gte`, day(spec.shelf === "new" ? -42 : 1));
        url.searchParams.set(`${date}.lte`, day(spec.shelf === "new" ? 0 : 90));
      }
    }

    try {
      const response = await fetch(url, {
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
        signal: AbortSignal.timeout(6000),
      });
      if (response.status === 404) throw new CatalogError(404, "unavailable");
      if (response.status === 429) {
        const delay = response.headers.get("Retry-After");
        throw new CatalogError(429, "provider_rate_limited", delay && /^\d{1,6}$/.test(delay) ? delay : "30");
      }
      if (!response.ok) throw new CatalogError(502, "provider_unavailable");
      const upstream = await body(response);
      let result: Json;
      let hydrated: Json | null = null;
      let retrySoon = false;
      let showChildren: Json[] | null = null;
      let showTmdb: number | null = null;
      let seasonTmdb: number | null = null;
      if (spec.operation === "hydrate") {
        hydrated = normalize(upstream, spec.kind);
        if (!hydrated || hydrated.tmdb_id !== spec.tmdb_id) throw new CatalogError(404, "unavailable");
        const genres = Array.isArray(upstream.genres)
          ? upstream.genres.map((item) => text(object(item).name, 60)).filter(Boolean)
          : [];
        const releases = spec.kind === "movie" ? regionalReleases(upstream) : undefined;
        const fresh = await externalRating(upstream);
        const previous = object(object(object(claim.value).details).rating);
        // An OMDb hiccup (timeout, daily limit) must not swap a known IMDb score for TMDB's.
        const rating = fresh?.source !== "imdb" && previous.source === "imdb" ? previous : fresh;
        // A TMDB fallback for a title that has an IMDb id is retried within the hour, not tomorrow.
        if (rating?.source !== "imdb" && rating?.imdb_id && Deno.env.get("OMDB_API_KEY")) retrySoon = true;
        result = { ...hydrated, genres, details: { ...details(upstream), genres, rating },
          ...(releases ? { regional_releases: releases } : {}) };
        if (spec.kind === "show" && Array.isArray(upstream.seasons) && upstream.seasons.length > 0) {
          showChildren = children(upstream.seasons, "season");
          showTmdb = spec.tmdb_id;
        }
      } else if (spec.operation === "hydrate_season") {
        if (upstream.season_number !== spec.season_number) throw new CatalogError(404, "unavailable");
        showChildren = children(upstream.episodes, "episode");
        showTmdb = spec.tmdb_id;
        seasonTmdb = number(upstream.id, 1);
        result = { season_tmdb_id: seasonTmdb, season_number: spec.season_number };
      } else if (spec.operation === "person") {
        const identity = person(upstream);
        if (!identity || identity.tmdb_id !== spec.tmdb_id) throw new CatalogError(404, "unavailable");
        const credits = object(upstream.combined_credits);
        const items = [...(Array.isArray(credits.cast) ? credits.cast : []),
          ...(Array.isArray(credits.crew) ? credits.crew.filter((x) => ["Director","Creator","Executive Producer"].includes(String(object(x).job))) : [])];
        const unique = new Map<string,Json>();
        for (const entry of items) {
          const row = object(entry);
          const title = row.media_type === "movie" ? normalize(row,"movie") : row.media_type === "tv" ? normalize(row,"show") : null;
          if (title && unique.size < 80) unique.set(`${title.kind}:${title.tmdb_id}`, title);
        }
        result = { ...identity, items: [...unique.values()] };
      } else {
        if (!Array.isArray(upstream.results)) throw new CatalogError(502, "invalid_upstream");
        const items = upstream.results.slice(0, 25).flatMap((value) => {
          const item = object(value);
          const kind = spec.operation === "trending" ? spec.kind :
            item.media_type === "movie" ? "movie" : item.media_type === "tv" ? "show" : null;
          // Shelves skip titles without a poster; search keeps them so they can still be found.
          const title = kind && (spec.operation !== "trending" || item.poster_path) ? normalize(item, kind) : null;
          return title ? [title] : [];
        });
        const end = typeof upstream.total_pages === "number" ? Math.min(10, upstream.total_pages) : spec.page;
        const people = spec.operation === "search" ? upstream.results.slice(0,25).flatMap((value) => {
          const item = object(value);
          const identity = item.media_type === "person" ? person(item) : null;
          return identity ? [identity] : [];
        }) : [];
        result = { items, people, next_page: spec.page < end ? spec.page + 1 : null };
      }
      const stored = await rpc(showChildren ? "catalog_finish_show" : "catalog_finish", {
        request_key: key,
        lease: claim.lease,
        ttl_seconds: retrySoon ? 3600 : spec.operation === "hydrate" || spec.operation === "person" ? 86400 :
          spec.operation === "hydrate_season" || spec.operation === "trending" ? 7200 : 900,
        result,
        hydrated,
        ...(showChildren ? { show_tmdb: showTmdb, season_tmdb: seasonTmdb, children: showChildren } : {}),
      });
      return { data: stored, fetched_at: new Date().toISOString(), stale: false };
    } catch (error) {
      if (claim.value && (!(error instanceof CatalogError) || error.status >= 429)) return cached();
      if (error instanceof CatalogError) throw error;
      throw new CatalogError(502, "provider_unavailable");
    }
}
