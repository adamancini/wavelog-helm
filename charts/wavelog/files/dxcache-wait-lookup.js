// Blocks until Wavelog answers a DXCC lookup with this key, so DXCache does
// not start enrichment against a Wavelog that is still installing.
const url = process.env.WAVELOG_URL;
const key = process.env.WAVELOG_KEY;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

for (;;) {
  let why;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, callsign: "DL1AA" }),
      signal: AbortSignal.timeout(5000),
    });
    if (res.status === 200) {
      const body = await res.json().catch(() => ({}));
      if (body && body.cont) {
        console.log("wavelog lookup ready");
        process.exit(0);
      }
      why = "200 without cont";
    } else {
      why = `status ${res.status}`;
    }
  } catch (e) {
    why = `error ${e && e.name ? e.name : "unknown"}`;
  }
  console.log(`wavelog lookup not ready: ${why}`);
  await sleep(5000);
}
