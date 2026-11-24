import { backendRequest, noCache, preflight, publicKey, reply, rpc } from "../_shared/backend.ts";

// Signs in by handle without ever sending the account's email to the client.
Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return reply("method_not_allowed", 405);
  if (!publicKey || request.headers.get("apikey") !== publicKey) return reply("unauthenticated", 401);
  try {
    const input = await request.text();
    if (input.length > 4096) return reply("invalid_request", 400);
    const data = JSON.parse(input);
    const { handle, password } = data ?? {};
    if (typeof handle !== "string" || !/^[a-z0-9_]{3,24}$/i.test(handle.trim()) ||
      typeof password !== "string" || password.length === 0 || password.length > 1024) {
      return reply("invalid_credentials", 400);
    }
    const email = await rpc<string | null>("account_email", { requested_handle: handle });
    // Same answer for an unknown handle and a wrong password, so handles can't be probed.
    if (!email) return reply("invalid_credentials", 400);
    // shortcut: GoTrue rate-limits by this function's IP, not the user's; add own per-handle limit if abused.
    const token = await backendRequest("/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: { apikey: publicKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    const body = await token.json();
    if (!token.ok) {
      const code = body?.error_code ?? body?.code;
      return reply(code === "email_not_confirmed" || code === "over_request_rate_limit" ? code : "invalid_credentials",
        token.status === 429 ? 429 : 400);
    }
    return Response.json({ refresh_token: body.refresh_token }, { headers: noCache });
  } catch {
    return reply("sign_in_unavailable", 503);
  }
});
