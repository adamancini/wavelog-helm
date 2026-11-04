// Blocks until Wavelog answers a DXCC lookup with this key, so DXCache does
// not start enrichment against a Wavelog that is still installing.
const url = process.env.WAVELOG_URL;
const key = process.env.WAVELOG_KEY;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Short single-line excerpt of a response body for the log (never the key).
const excerpt = (s) => String(s).replace(/\s+/g, " ").trim().slice(0, 120);

for (;;) {
  let why;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, callsign: "N0CALL" }),
      signal: AbortSignal.timeout(5000),
    });
    const text = await res.text();
    if (res.status === 200) {
      let body = {};
      try {
        body = JSON.parse(text);
      } catch {}
      if (body && body.cont) {
        console.log("wavelog lookup ready");
        process.exit(0);
      }
      why = `200 without cont: ${excerpt(text)}`;
    } else {
      why = `status ${res.status}: ${excerpt(text)}`;
    }
  } catch (e) {
    why = `error ${(e && e.name) || "Error"}: ${(e && e.message) || String(e)}`;
  }
  console.log(`wavelog lookup not ready: ${why}`);
  await sleep(5000);
}
