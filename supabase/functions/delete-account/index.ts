import { backendRequest, clientHeaders, idPattern, preflight, publicKey, reply, rpc, signedIn } from "../_shared/backend.ts";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return reply("method_not_allowed",405);
  try {
    const headers = clientHeaders(request);
    if (!headers) return reply("unauthenticated",401);
    const user = await signedIn(headers);
    if (typeof user?.id !== "string" || !idPattern.test(user.id) || typeof user.email !== "string" ||
      !user.email_confirmed_at) return reply("unauthenticated",401);
    const input = await request.text();
    if (input.length > 4096) return reply("invalid_request",400);
    const data = JSON.parse(input);
    if (data?.confirm !== true || typeof data?.password !== "string" || data.password.length === 0 ||
        data.password.length > 1024) return reply("invalid_request",400);
    const challenge = await backendRequest("/auth/v1/token?grant_type=password", {
      method: "POST", headers: { apikey: publicKey!, "Content-Type": "application/json" },
      body: JSON.stringify({ email: user.email, password: data.password }),
    });
    if (!challenge.ok) return reply("reverification_failed",403);
    const confirmation = await challenge.json();
    if (confirmation?.user?.id !== user.id) return reply("reverification_failed",403);
    await rpc("request_account_deletion", { actor: user.id });
    if (typeof confirmation.access_token === "string") {
      await backendRequest("/auth/v1/logout?scope=global", {
        method: "POST", headers: { apikey: publicKey!, Authorization: `Bearer ${confirmation.access_token}` },
      }).catch(() => {});
    }
    return reply("accepted",202);
  } catch {
    return reply("deletion_unavailable",503);
  }
});
