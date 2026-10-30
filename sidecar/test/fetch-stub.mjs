// Preloaded into the smoke-test sidecar so no request leaves the machine. Every provider call
// gets a 401 whose message echoes the credential the sidecar sent, so tests can see which one won.
globalThis.fetch = async (_url, init) => {
  const headers = new Headers(init?.headers);
  const sent = headers.get("authorization") ?? headers.get("x-api-key") ?? "none";
  const body = { type: "error", error: { type: "authentication_error", message: `fetch-stub saw ${sent}` } };
  return new Response(JSON.stringify(body), { status: 401, headers: { "content-type": "application/json" } });
};
