import { idPattern, noCache, publicKey, reply, rpc } from "../_shared/backend.ts";

Deno.serve(async (request) => {
  if (request.method !== "GET") return reply("method_not_allowed",405);
  const url = new URL(request.url);
  const [kind,id] = url.pathname.split("/").slice(-2);
  if (!["review","title"].includes(kind) || !idPattern.test(id) || !publicKey) return reply("unavailable",404);
  try {
    const result = await rpc<Record<string,unknown> | null>("public_share", { kind_value: kind, target: id }, { apikey: publicKey });
    if (!result) return reply("unavailable",404);
    const destination = `com.taspa.taspa://share/${kind}/${id}`;
    if (url.searchParams.get("preview") === "1") {
      return Response.json({ label: result.label, destination }, { headers: noCache });
    }
    return new Response(null, { status: 302, headers: { ...noCache, Location: destination } });
  } catch { return reply("unavailable",503); }
});
