import { backendRequest, clientHeaders, idPattern, noCache, preflight, reply, rpc, serviceHeaders, signedIn } from "../_shared/backend.ts";

function png(bytes: ArrayBuffer): boolean {
  if (bytes.byteLength < 33 || bytes.byteLength > 1024 * 1024) return false;
  const bits = new DataView(bytes);
  return bits.getUint32(0) === 0x89504e47 && bits.getUint32(4) === 0x0d0a1a0a &&
    bits.getUint32(8) === 13 && bits.getUint32(12) === 0x49484452 &&
    bits.getUint32(16) > 0 && bits.getUint32(16) <= 512 &&
    bits.getUint32(20) > 0 && bits.getUint32(20) <= 512;
}

async function remove(path: string): Promise<void> {
  await backendRequest("/storage/v1/object/avatars", {
    method: "DELETE", headers: { ...serviceHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify({ prefixes: [path] }),
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  try {
    const reading = request.method === "GET";
    const headers = clientHeaders(request, reading);
    if (!headers) return reply("unauthenticated",401);
    if (reading) {
      const target = new URL(request.url).searchParams.get("user") ?? "";
      if (!idPattern.test(target)) return reply("unavailable",404);
      const path = await rpc<string | null>("avatar_path", { target }, headers);
      if (!path || !path.startsWith(target + "/")) return reply("unavailable",404);
      const result = await backendRequest(`/storage/v1/object/avatars/${path}`, { headers: serviceHeaders() });
      if (!result.ok) return reply("unavailable",404);
      return new Response(result.body, { headers: { ...noCache, "Content-Type": "image/png" } });
    }
    if (!["POST","DELETE"].includes(request.method)) return reply("method_not_allowed",405);
    const user = await signedIn(headers);
    if (typeof user?.id !== "string" || !idPattern.test(user.id)) return reply("unauthenticated",401);
    let path: string | null = null;
    if (request.method === "POST") {
      if (request.headers.get("Content-Type") !== "image/png" ||
          Number(request.headers.get("Content-Length")) > 1024*1024) return reply("invalid_image",400);
      const bytes = await request.arrayBuffer();
      if (!png(bytes)) return reply("invalid_image",400);
      path = `${user.id}/${crypto.randomUUID()}.png`;
      const result = await backendRequest(`/storage/v1/object/avatars/${path}`, {
        method: "POST", headers: { ...serviceHeaders(), "Content-Type": "image/png" }, body: bytes,
      });
      if (!result.ok) return reply("unavailable",503);
    }
    let prior: string | null;
    try {
      prior = await rpc<string | null>("avatar_swap", { actor: user.id, path_value: path });
    } catch (error) {
      if (path) await remove(path).catch(() => {});
      throw error;
    }
    if (prior) await remove(prior).catch(() => {});
    return reply("saved",200);
  } catch {
    return reply("avatar_unavailable",503);
  }
});
