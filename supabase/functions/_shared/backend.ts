export type Json = Record<string, unknown>;

export const base = Deno.env.get("SUPABASE_URL");
function getKey(object: string, current: string, legacy: string): string | undefined {
  const value = Deno.env.get(object);
  return (value ? JSON.parse(value).default : null) ?? Deno.env.get(current) ?? Deno.env.get(legacy);
}
export const publicKey = getKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY");
const serviceKey = getKey("SUPABASE_SECRET_KEYS", "SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY");

export function serviceHeaders(): Record<string,string> {
  if (!serviceKey) throw new Error("backend_unconfigured");
  return {
    apikey: serviceKey,
    ...(!serviceKey.startsWith("sb_secret_") ? { Authorization: `Bearer ${serviceKey}` } : {}),
  };
}

export function clientHeaders(request: Request, allowGuest = false): Record<string,string> | null {
  if (!publicKey || request.headers.get("apikey") !== publicKey) return null;
  const auth = request.headers.get("Authorization");
  if (auth && auth !== `Bearer ${publicKey}`) {
    if (!/^Bearer [^\s]+$/.test(auth) || auth.length > 4096) return null;
    return { apikey: publicKey, Authorization: auth };
  }
  return allowGuest ? { apikey: publicKey } : null;
}

export async function backendRequest(path: string, init: RequestInit): Promise<Response> {
  if (!base) throw new Error("backend_unconfigured");
  return await fetch(base + path, { ...init, signal: AbortSignal.timeout(8000) });
}

export async function rpc<T>(name: string, params: Json, headers = serviceHeaders()): Promise<T> {
  const response = await backendRequest(`/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json", "Content-Profile": "api" },
    body: JSON.stringify(params),
  });
  if (!response.ok) throw new Error(`backend_request_failed:${name}:${response.status}:${(await response.text()).slice(0, 200)}`);
  return (response.status === 204 ? null : await response.json()) as T;
}

export async function signedIn(headers: Record<string, string>): Promise<Json | null> {
  if (!headers.Authorization) return null;
  const response = await backendRequest("/auth/v1/user", { headers });
  return response.ok ? await response.json() : null;
}

export const idPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const noCache = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
export function reply(code: string, status: number): Response {
  return Response.json({ code }, { status, headers: noCache });
}
