// Catalog gateway: TMDB proxy with a shared database cache. The work itself lives in _shared/catalog_core.ts
// so must-import can hydrate titles without calling this function over HTTP.
import { body, CatalogError, defaultKey, parse, runCatalog } from "../_shared/catalog_core.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};

function reply(status: number, value: Record<string, unknown>, retryAfter?: string): Response {
  return Response.json(value, {
    status,
    headers: { ...cors, "Cache-Control": "no-store", ...(retryAfter ? { "Retry-After": retryAfter } : {}) },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: cors });
  if (request.method !== "POST") return reply(405, { code: "method_not_allowed" });
  const requestId = crypto.randomUUID();
  try {
    const base = Deno.env.get("SUPABASE_URL");
    const publishable = defaultKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY");
    if (!base || !publishable) throw new CatalogError(503, "catalog_unconfigured");
    if (request.headers.get("apikey") !== publishable) throw new CatalogError(401, "unauthenticated");

    const authorization = request.headers.get("Authorization");
    let actor = request.headers.get("cf-connecting-ip")?.slice(0, 64) ?? "guest";
    if (authorization && authorization !== `Bearer ${publishable}`) {
      if (!authorization.startsWith("Bearer ") || authorization.length > 4096) {
        throw new CatalogError(401, "unauthenticated");
      }
      const response = await fetch(`${base}/auth/v1/user`, {
        headers: { apikey: publishable, Authorization: authorization },
        signal: AbortSignal.timeout(4500),
      });
      if (!response.ok) throw new CatalogError(response.status >= 500 ? 503 : 401, "auth_unavailable");
      const id = (await body(response)).id;
      if (typeof id !== "string") throw new CatalogError(401, "unauthenticated");
      actor = id;
    }
    const raw = await request.text();
    if (raw.length > 2048) throw new CatalogError(400, "invalid_catalog_request");
    let parsed: unknown;
    try { parsed = JSON.parse(raw); } catch { throw new CatalogError(400, "invalid_json"); }
    return reply(200, await runCatalog(parse(parsed), actor));
  } catch (error) {
    const failure = error instanceof CatalogError ? error : new CatalogError(503, "catalog_unavailable");
    console.warn(JSON.stringify({ request_id: requestId, status: failure.status, code: failure.code }));
    return reply(failure.status, { code: failure.code, request_id: requestId }, failure.retryAfter);
  }
});
