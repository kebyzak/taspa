// Import from Must (mustapp.com) by public username.
// shortcut: Must has no official API; this uses the endpoints its website calls (same as the open-source
// "export-mustapp-data" tool). If Must changes them, only this file needs fixing.
//
// POST {action:"start", username}  reads the Must profile once and stores every title as an import item.
// POST {action:"step"}             matches the next items to TMDB, hydrates them with the shared catalog core
//                                  and writes them; the app repeats it until state is "done".
import { base, backendRequest, clientHeaders, Json, noCache, publicKey, rpc, signedIn } from "../_shared/backend.ts";
import { CatalogError, parse, runCatalog } from "../_shared/catalog_core.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};
const MUST = "https://mustapp.com/api";
const STEP_BUDGET_MS = 20_000;
const CRON_BUDGET_MS = 50_000;

/** Same shared-secret check as the maintenance function (TASPA_WORKER_KEY, compared by hash). */
async function workerAuthorized(received: string | null): Promise<boolean> {
  const expected = Deno.env.get("TASPA_WORKER_KEY");
  if (!expected || !received || received.length > 128) return false;
  const digest = async (value: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([digest(expected), digest(received)]);
  return a.every((byte, i) => byte === b[i]);
}

class ImportError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: number) { super(code); }
}

function send(status: number, value: Json): Response {
  return Response.json(value, { status, headers: { ...cors, ...noCache } });
}

function object(value: unknown): Json {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Json : {};
}

async function must(path: string, token: string, body?: unknown, attempt = 0): Promise<unknown> {
  let response: Response;
  try {
    response = await fetchMust(path, token, body);
  } catch (error) {
    // Must is sometimes slow; a timed-out or dropped request is retried twice before the import gives up.
    if (attempt < 2) return await must(path, token, body, attempt + 1);
    console.warn(JSON.stringify({ must_path: path.split("?")[0].replace(/\d+/g, "N"), error: String(error) }));
    throw new ImportError(502, "must_unavailable");
  }
  if (response.status >= 500 && attempt < 2) return await must(path, token, body, attempt + 1);
  if (response.status === 404) throw new ImportError(404, "must_user_not_found");
  if (!response.ok) {
    console.warn(JSON.stringify({ must_path: path.split("?")[0].replace(/\d+/g, "N"), status: response.status }));
    throw new ImportError(502, "must_unavailable");
  }
  return await response.json();
}

function fetchMust(path: string, token: string, body?: unknown): Promise<Response> {
  return fetch(`${MUST}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      accept: "application/json",
      "accept-language": "en",
      bearer: token,
      "x-requested-with": "XMLHttpRequest",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
}

/** Reads the whole public Must profile into import items. */
async function readMust(username: string): Promise<Json[]> {
  const token = object(await must("/acc/anonymous", "", {})).token;
  if (typeof token !== "string") throw new ImportError(502, "must_unavailable");
  const profile = object(await must(`/users/uri/${encodeURIComponent(username)}`, token));
  const lists = object(profile.lists);
  if (profile.is_private === true || typeof profile.id !== "number" || !profile.lists) {
    throw new ImportError(409, "must_profile_private");
  }
  const membership = new Map<number, string[]>();
  for (const name of ["want", "shows", "watched"]) {
    const ids = lists[name];
    if (!Array.isArray(ids)) continue;
    for (const id of ids) {
      if (typeof id === "number" && Number.isSafeInteger(id)) membership.set(id, [...(membership.get(id) ?? []), name]);
    }
  }
  const ids = [...membership.keys()];
  if (ids.length > 20000) throw new ImportError(413, "must_library_too_large");
  const items: Json[] = [];
  for (let start = 0; start < ids.length; start += 100) {
    const batch = ids.slice(start, start + 100);
    const products = await must(`/users/id/${profile.id}/products?embed=product`, token, { ids: batch });
    const reviews = await must(`/users/id/${profile.id}/products?embed=review`, token, { ids: batch }).catch(() => []);
    const reviewById = new Map<number, string>();
    if (Array.isArray(reviews)) {
      reviews.forEach((value, index) => {
        const body = object(object(object(value).user_product_info).review).body;
        if (typeof body === "string" && body.trim()) reviewById.set(batch[index], body.trim().slice(0, 5000));
      });
    }
    if (!Array.isArray(products)) throw new ImportError(502, "must_unavailable");
    for (const value of products) {
      const product = object(object(value).product);
      const info = object(object(value).user_product_info);
      const id = product.id;
      const kind = product.type === "movie" ? "movie" : product.type === "show" ? "show" : null;
      if (typeof id !== "number" || !kind || typeof product.title !== "string") continue;
      const year = typeof product.release_date === "string" ? Number(product.release_date.slice(0, 4)) : NaN;
      const episodes = object(info.user_show_info).episodes_watched;
      items.push({
        must_id: id,
        kind,
        title: product.title.slice(0, 300),
        year: Number.isInteger(year) && year > 1800 ? year : null,
        lists: membership.get(id) ?? [],
        rate: typeof info.rate === "number" ? info.rate : null,
        modified_at: typeof info.modified_at === "string" && !Number.isNaN(Date.parse(info.modified_at)) ? info.modified_at : null,
        episodes: typeof episodes === "number" && Number.isSafeInteger(episodes) && episodes > 0 ? episodes : 0,
        review: reviewById.get(id) ?? null,
      });
    }
  }
  return items;
}

/** Finds the TMDB id for a Must title by name and year. */
async function matchTmdb(kind: "movie" | "show", title: string, year: number | null): Promise<number | null> {
  const token = Deno.env.get("TMDB_READ_ACCESS_TOKEN");
  if (!token) throw new ImportError(503, "import_unconfigured");
  const search = async (withYear: boolean): Promise<Json[]> => {
    const url = new URL(`https://api.themoviedb.org/3/search/${kind === "show" ? "tv" : "movie"}`);
    url.searchParams.set("query", title);
    url.searchParams.set("include_adult", "false");
    if (withYear && year) url.searchParams.set(kind === "show" ? "first_air_date_year" : "primary_release_year", String(year));
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(6000),
    });
    if (response.status === 429) throw new ImportError(429, "provider_rate_limited", 10);
    if (!response.ok) throw new ImportError(502, "provider_unavailable");
    const results = object(await response.json()).results;
    return Array.isArray(results) ? results.map(object) : [];
  };
  let results = await search(true);
  if (results.length === 0 && year) results = await search(false);
  const name = (row: Json) => String(kind === "show" ? row.name : row.title).toLowerCase();
  const original = (row: Json) => String(kind === "show" ? row.original_name : row.original_title).toLowerCase();
  const wanted = title.toLowerCase();
  const pick = results.find((row) => name(row) === wanted || original(row) === wanted) ?? results[0];
  return typeof pick?.id === "number" ? pick.id : null;
}

/** Runs a catalog operation as the user, so titles, seasons and episodes land in the database the usual way. */
/** Runs a catalog operation in-process (no function-to-function call), so titles, seasons and episodes land
 * in the database the usual way. `actor` only keys the catalog's per-caller budget. */
async function catalog(actor: string, input: Json): Promise<Json> {
  try {
    return object((await runCatalog(parse(input), actor)).data);
  } catch (error) {
    if (!(error instanceof CatalogError)) throw error;
    if (error.status === 429) throw new ImportError(429, "catalog_busy", Number(error.retryAfter) || 15);
    if (error.status === 404) return {};
    throw new ImportError(502, `catalog_${error.code}`);
  }
}

/** A title already in the catalog (from an earlier import or browsing) needs no TMDB call. */
async function storedTitle(auth: string, kind: string, tmdbId: number): Promise<Json | null> {
  const response = await backendRequest(
    `/rest/v1/titles?kind=eq.${kind}&tmdb_id=eq.${tmdbId}&catalog_state=eq.available&select=id&limit=1`,
    { headers: { apikey: publicKey!, ...(auth === `Bearer ${publicKey}` ? {} : { Authorization: auth }), "Accept-Profile": "api" } },
  );
  if (!response.ok) return null;
  const rows = await response.json();
  return Array.isArray(rows) && rows.length > 0 ? object(rows[0]) : null;
}

/** Loads enough seasons of a show for the first `count` episodes to exist. */
async function loadSeasons(auth: string, show: string, tmdbId: number, count: number): Promise<void> {
  const response = await backendRequest(
    `/rest/v1/seasons?show_id=eq.${show}&available=eq.true&season_number=gt.0&select=season_number,expected_episodes,loaded_at&order=season_number`,
    // Read as the caller (user or guest): api.seasons is granted to anon/authenticated, not to the service role.
    { headers: { apikey: publicKey!, ...(auth === `Bearer ${publicKey}` ? {} : { Authorization: auth }), "Accept-Profile": "api" } },
  );
  if (!response.ok) throw new Error(`seasons_read_failed:${response.status}`);
  let covered = 0;
  for (const season of await response.json() as Json[]) {
    if (covered >= count) break;
    if (!season.loaded_at) await catalog(auth, { operation: "hydrate_season", tmdb_id: tmdbId, season_number: season.season_number });
    covered += Number(season.expected_episodes) || 0;
  }
}

async function step(auth: string, job: Json, budget = STEP_BUDGET_MS): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < budget) {
    const items = await rpc<Json[]>("import_next", { job: job.id, max_items: 10 });
    if (items.length === 0) {
      await rpc("import_finish", { job: job.id });
      break;
    }
    for (const item of items) {
      if (Date.now() - started >= budget) break;
      try {
        const kind = item.kind as "movie" | "show";
        const match = object(item.match);
        const tmdbId = typeof match.tmdb_id === "number" && match.kind === kind
          ? match.tmdb_id
          : await matchTmdb(kind, String(item.title), typeof item.year === "number" ? item.year : null);
        const title = !tmdbId ? {}
          : await storedTitle(auth, kind, tmdbId) ?? await catalog(auth, { operation: "hydrate", kind, tmdb_id: tmdbId });
        if (typeof title.id !== "string") {
          await rpc("import_skip", { job: job.id, item: item.must_id, note: tmdbId ? "not_in_catalog" : "no_tmdb_match" });
          continue;
        }
        const episodes = Number(item.episodes) || 0;
        if (kind === "show" && episodes > 0) await loadSeasons(auth, title.id, tmdbId!, episodes);
        await rpc("import_apply", { job: job.id, item: item.must_id, title: title.id });
      } catch (error) {
        // Rate limits and timeouts pause the import (the app retries the same title later);
        // any other failure only drops this title.
        if (error instanceof ImportError && error.status === 429) throw error;
        if (error instanceof DOMException || error instanceof TypeError) throw new ImportError(429, "import_slow", 10);
        if (error instanceof Error && error.name === "RateLimitError") {
          const wait = Number(/Retry after (\d+)ms/.exec(error.message)?.[1]);
          throw new ImportError(429, "import_slow", Number.isFinite(wait) ? Math.ceil(wait / 1000) : 30);
        }
        console.warn(JSON.stringify({ import_item_failed: String(error) }));
        await rpc("import_skip", { job: job.id, item: item.must_id, note: String(error).slice(0, 300) });
      }
    }
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: cors });
  if (request.method !== "POST") return send(405, { code: "method_not_allowed" });
  try {
    // Background worker (pg_cron, once a minute): advance running imports while the app is closed.
    if (request.headers.has("x-taspa-worker")) {
      if (!publicKey || !await workerAuthorized(request.headers.get("x-taspa-worker"))) {
        throw new ImportError(401, "unauthenticated");
      }
      const started = Date.now();
      let processed = 0;
      for (const job of await rpc<Json[]>("import_running", {})) {
        const left = CRON_BUDGET_MS - (Date.now() - started);
        if (left < 5_000) break;
        try {
          // Without the user's session the catalog is called as a guest; it writes the same titles.
          await step(`Bearer ${publicKey}`, job, Math.min(left, CRON_BUDGET_MS / 2));
          processed++;
        } catch (error) {
          if (error instanceof ImportError && error.status === 429) break; // Rate limited: next minute.
          throw error;
        }
      }
      return send(200, { processed });
    }
    const headers = clientHeaders(request);
    if (!headers || !base || !publicKey) throw new ImportError(401, "unauthenticated");
    const user = await signedIn(headers);
    if (typeof user?.id !== "string") throw new ImportError(401, "unauthenticated");
    const raw = await request.text();
    if (raw.length > 512) throw new ImportError(400, "invalid_request");
    const input = object(JSON.parse(raw || "{}"));

    if (input.action === "start") {
      const username = String(input.username ?? "").trim()
        .replace(/^https?:\/\/(www\.)?mustapp\.com\//i, "").replace(/^@/, "").replace(/[?#/].*$/, "");
      if (!/^[A-Za-z0-9_.-]{1,64}$/.test(username)) throw new ImportError(400, "invalid_username");
      const current = await rpc<Json | null>("import_status", {}, headers);
      if (current?.state === "running") return send(200, current);
      const items = await readMust(username);
      if (items.length === 0) throw new ImportError(404, "must_library_empty");
      await rpc("import_start", { actor: user.id, username, items });
      return send(200, await rpc<Json>("import_status", {}, headers));
    }
    if (input.action === "step") {
      const job = await rpc<Json | null>("import_status", {}, headers);
      if (job?.state !== "running") return send(200, job ?? {});
      await step(headers.Authorization, job);
      return send(200, await rpc<Json>("import_status", {}, headers));
    }
    throw new ImportError(400, "invalid_request");
  } catch (error) {
    const failure = error instanceof ImportError ? error : new ImportError(503, "import_unavailable");
    if (!(error instanceof ImportError)) console.warn(String(error));
    return Response.json({ code: failure.code, ...(failure.retryAfter ? { retry_after: failure.retryAfter } : {}) },
      { status: failure.status, headers: { ...cors, ...noCache } });
  }
});
