import { backendRequest, idPattern, serviceHeaders } from "../_shared/backend.ts";

const firebaseProject = "taspa-4ea43";
const oauthUrl = "https://oauth2.googleapis.com/token";
const fcmUrl = `https://fcm.googleapis.com/v1/projects/${firebaseProject}/messages:send`;

type Json = Record<string, unknown>;
type Claim = { notification_id: string; lease_id: string };
type Refresh = { kind: string; tmdb_id: number; season_number: number | null };

function defaultServiceKey(): string | undefined {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  return (keys ? JSON.parse(keys).default : null) ??
    Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
}

async function rpc<T>(name: string, args: Json = {}): Promise<T> {
  const service = defaultServiceKey();
  const base = Deno.env.get("SUPABASE_URL");
  if (!service || !base) throw new Error("database_unconfigured");
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: service,
      ...(!service.startsWith("sb_secret_") ? { Authorization: `Bearer ${service}` } : {}),
      "Content-Type": "application/json",
      "Content-Profile": "api",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error("database_request_failed");
  return (response.status === 204 ? null : await response.json()) as T;
}

const encoder = new TextEncoder();
function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function encode(value: Json): string {
  return base64url(encoder.encode(JSON.stringify(value)));
}

let token: { value: string; until: number } | undefined;
async function senderToken(): Promise<string> {
  if (token && token.until > Date.now() + 60000) return token.value;
  const configured = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!configured) throw new Error("fcm_unconfigured");
  const account = JSON.parse(configured) as Json;
  if (account.type !== "service_account" || account.project_id !== firebaseProject ||
      typeof account.client_email !== "string" || typeof account.private_key !== "string") {
    throw new Error("fcm_configuration_invalid");
  }
  const pem = account.private_key.replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8", Uint8Array.from(atob(pem), (ch) => ch.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({
    iss: account.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: oauthUrl, iat: now, exp: now + 3600,
  })}`;
  const signed = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(unsigned));
  const response = await fetch(oauthUrl, {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${base64url(new Uint8Array(signed))}`,
    }),
    signal: AbortSignal.timeout(7000),
  });
  if (!response.ok) throw new Error("fcm_oauth_rejected");
  const data = await response.json();
  if (typeof data.access_token !== "string" || typeof data.expires_in !== "number") {
    throw new Error("fcm_oauth_invalid");
  }
  token = { value: data.access_token, until: Date.now() + data.expires_in * 1000 };
  return token.value;
}

async function authorized(received: string | null): Promise<boolean> {
  const expected = Deno.env.get("TASPA_WORKER_KEY");
  if (!expected || !received || received.length > 128) return false;
  const [a, b] = await Promise.all([expected, received].map(async (value) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)))));
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function send(accessToken: string, payload: Json): Promise<Response> {
  return await fetch(fcmUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(6500),
  });
}

async function deliver(accessToken: string, item: Claim): Promise<string> {
  let outcome = "retry";
  try {
    const destination = await rpc<string | null>("push_destination", { claim: item.lease_id });
    if (!destination) {
      outcome = "skipped";
    } else {
      const response = await send(accessToken, {
        message: {
          token: destination,
          data: { notification_id: item.notification_id },
          android: {
            ttl: "1800s",
            notification: {
              title: "Taspa",
              body: "You have a new update.",
              tag: item.notification_id,
            },
          },
        },
      });
      if (response.ok) {
        outcome = "sent";
      } else {
        const error = await response.json().catch(() => null);
        const unregistered = Array.isArray(error?.error?.details) &&
          error.error.details.some((item: Json) => item.errorCode === "UNREGISTERED");
        if (unregistered) outcome = "unregistered";
        else if (response.status === 400) outcome = "rejected";
        else if (response.status === 401) token = undefined;
      }
    }
  } catch {
    // Leave transport and database timeouts retryable, including an ambiguous send result.
  }
  await rpc("push_finish", { claim: item.lease_id, result_code: outcome });
  return outcome;
}

async function refreshCatalog(): Promise<Json> {
  const base = Deno.env.get("SUPABASE_URL");
  const keys = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  const key = (keys ? JSON.parse(keys).default : null) ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !key) throw new Error("catalog_unconfigured");
  const batch = await rpc<Refresh[]>("catalog_refresh_targets");
  const outcome = await Promise.all(batch.map(async (entry) => {
    const request = entry.season_number === null
      ? { operation: "hydrate", tmdb_id: entry.tmdb_id, kind: entry.kind }
      : { operation: "hydrate_season", tmdb_id: entry.tmdb_id, season_number: entry.season_number };
    try {
      const result = await fetch(`${base}/functions/v1/catalog`, {
        method: "POST", headers: { apikey: key, "Content-Type": "application/json" },
        body: JSON.stringify(request), signal: AbortSignal.timeout(17000),
      });
      return result.ok;
    } catch { return false; }
  }));
  return { processed: outcome.length, accepted: outcome.filter(Boolean).length };
}

async function deleteAccounts(): Promise<number> {
  const jobs = await rpc<{ user_id: string }[]>("claim_account_deletions");
  let finished = 0;
  for (const job of jobs) {
    const actor = job.user_id;
    if (!idPattern.test(actor)) continue;
    try {
      const headers = { ...serviceHeaders(), "Content-Type": "application/json" };
      const listed = await backendRequest("/storage/v1/object/list/avatars", {
        method: "POST", headers, body: JSON.stringify({ prefix: actor, limit: 100 }),
      });
      if (!listed.ok) continue;
      const files = await listed.json();
      if (!Array.isArray(files)) continue;
      const paths = files.filter((file) => typeof file?.name === "string" && /^[0-9a-f-]{36}\.png$/.test(file.name))
        .map((file) => `${actor}/${file.name}`);
      if (paths.length) {
        const removed = await backendRequest("/storage/v1/object/avatars", {
          method: "DELETE", headers, body: JSON.stringify({ prefixes: paths }),
        });
        if (!removed.ok || paths.length >= 100) continue;
      }
      const deleted = await backendRequest(`/auth/v1/admin/users/${actor}`, { method: "DELETE", headers });
      if (!deleted.ok && deleted.status !== 404) continue;
      await rpc("finish_account_deletion", { actor });
      finished++;
    } catch {
      // The durable job remains due for a later retry.
    }
  }
  return finished;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ code: "method_not_allowed" }, { status: 405 });
  if (!await authorized(request.headers.get("x-taspa-worker"))) {
    return Response.json({ code: "unauthorized" }, { status: 401 });
  }
  try {
    const payload = await request.json().catch(() => null);
    if (!payload || !["push", "fcm_check", "refresh", "deletions"].includes(payload.job)) {
      return Response.json({ code: "invalid_job" }, { status: 400 });
    }
    if (payload.job === "refresh") return Response.json(await refreshCatalog());
    if (payload.job === "deletions") return Response.json({ processed: await deleteAccounts() });
    if (payload.job === "fcm_check") {
      const response = await send(await senderToken(), {
        validate_only: true, message: {
          topic: "taspa_dry_run",
          android: { notification: { title: "Taspa", body: "Configuration check." } },
        },
      });
      return Response.json({ ok: response.ok, provider_status: response.status }, { status: response.ok ? 200 : 502 });
    }
    const batch = await rpc<Claim[]>("push_claim");
    if (batch.length === 0) return Response.json({ processed: 0 });
    const accessToken = await senderToken();
    const counts: Record<string, number> = {};
    for (let i = 0; i < batch.length; i += 5) {
      const outcomes = await Promise.all(batch.slice(i, i + 5).map((item) => deliver(accessToken, item)));
      for (const outcome of outcomes) counts[outcome] = (counts[outcome] ?? 0) + 1;
    }
    return Response.json({ processed: batch.length, counts });
  } catch {
    return Response.json({ code: "maintenance_unavailable" }, { status: 503 });
  }
});
