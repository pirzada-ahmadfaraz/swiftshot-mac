// SwiftShot Cloudflare Worker — one Worker, two hostnames:
//
//   up.swiftshot.online   POST  → authenticated upload to R2, returns {url}
//   i.swiftshot.online    GET   → branded viewer page (browser) OR raw image
//                                 bytes (embeds / unfurls / ?raw / /<token>/raw)
//
// Bindings/vars (set in the Worker's Settings):
//   BUCKET        R2 bucket binding → "screenshots"
//   PUBLIC_BASE   text var → "https://i.swiftshot.online"
//   UPLOAD_TOKEN  secret  → the bearer token the app sends
//
// IMPORTANT: i.swiftshot.online must be a CUSTOM DOMAIN on THIS Worker (not an
// R2 custom domain) so the Worker can intercept GETs and render the viewer.

const SITE = "https://swiftshot.online";
const TOKEN_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"; // lowercase + digits

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // --- Upload host -------------------------------------------------------
    if (url.hostname.startsWith("up.")) {
      if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
      return handleUpload(request, env);
    }

    // --- Image host (viewer + raw) ----------------------------------------
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    let path = url.pathname.replace(/^\/+/, "");
    if (path === "" || path === "favicon.ico") return Response.redirect(SITE, 302);

    // /<token>/raw forces raw bytes.
    let forceRaw = false;
    if (path.endsWith("/raw")) { forceRaw = true; path = path.slice(0, -4); }

    const key = path;
    if (!/^[a-z0-9]{4,16}$/.test(key)) return notFound();

    const accept = request.headers.get("Accept") || "";
    // Serve raw when explicitly asked, or when the client clearly wants an image
    // and NOT a document (e.g. an <img> tag). Browsers + crawlers send text/html
    // → they get the branded viewer with Open Graph tags.
    const wantRaw =
      forceRaw ||
      url.searchParams.has("raw") ||
      (accept.includes("image/") && !accept.includes("text/html"));

    if (wantRaw) return serveRaw(env, key, url.searchParams.has("download"));

    const head = await env.BUCKET.head(key);
    if (!head) return notFound();
    return new Response(viewerHTML(env, key), {
      headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" },
    });
  },
};

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

async function handleUpload(request, env) {
  if (request.headers.get("Authorization") !== `Bearer ${env.UPLOAD_TOKEN}`) {
    return new Response("Unauthorized", { status: 401 });
  }
  const form = await request.formData();
  const file = form.get("file");
  if (!file || typeof file === "string") return new Response("No file", { status: 400 });

  let key;
  for (let i = 0; i < 5; i++) {
    key = randomToken(6);
    if (!(await env.BUCKET.head(key))) break;
  }
  const contentType = file.type || mimeFromName(file.name);
  await env.BUCKET.put(key, file.stream(), { httpMetadata: { contentType } });

  return Response.json({ url: `${env.PUBLIC_BASE}/${key}` });
}

// ---------------------------------------------------------------------------
// Raw image
// ---------------------------------------------------------------------------

async function serveRaw(env, key, download) {
  const obj = await env.BUCKET.get(key);
  if (!obj) return notFound();

  const headers = new Headers();
  obj.writeHttpMetadata(headers); // content-type from stored metadata
  headers.set("etag", obj.httpEtag);
  headers.set("cache-control", "public, max-age=31536000, immutable");
  if (download) {
    const ext = extFromType(headers.get("content-type"));
    headers.set("content-disposition", `attachment; filename="swiftshot-${key}.${ext}"`);
  }
  return new Response(obj.body, { headers });
}

// ---------------------------------------------------------------------------
// Branded viewer page (matches the swiftshot.online theme)
// ---------------------------------------------------------------------------

function viewerHTML(env, key) {
  const base = env.PUBLIC_BASE;
  const pageURL = `${base}/${key}`;
  const rawURL = `${base}/${key}/raw`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Screenshot · SwiftShot</title>
<meta name="theme-color" content="#F7F9FF">
<meta property="og:title" content="Screenshot shared with SwiftShot">
<meta property="og:description" content="Captured & shared with SwiftShot — native macOS screenshots with markup and on-device OCR.">
<meta property="og:image" content="${rawURL}">
<meta property="og:url" content="${pageURL}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="SwiftShot">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="${rawURL}">
<link rel="icon" type="image/svg+xml" href="${SITE}/assets/logo.svg">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">
<style>
  :root{
    --ink:#070A12; --slate:#334155; --muted:#7B879D; --canvas:#F7F9FF;
    --surface:#fff; --border:#DDE5F4; --blue:#4F6BFF; --violet:#8B5CF6; --orange:#FF8A3D;
    --grad:linear-gradient(135deg,#4F6BFF 0%,#8B5CF6 55%,#FF8A3D 100%);
    --shadow-lift:0 4px 10px rgba(50,70,120,.08),0 24px 64px rgba(50,70,120,.16);
    --r-md:12px; --r-lg:18px;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html{-webkit-font-smoothing:antialiased}
  body{
    font-family:"Inter",-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    color:var(--ink); background:var(--canvas);
    min-height:100vh; display:flex; flex-direction:column;
    background-image:
      radial-gradient(60% 50% at 50% -10%, rgba(79,107,255,.10), transparent 70%),
      radial-gradient(40% 40% at 95% 0%, rgba(255,138,61,.08), transparent 70%);
  }
  a{color:inherit;text-decoration:none}
  .nav{
    position:sticky; top:0; z-index:5;
    display:flex; align-items:center; justify-content:space-between;
    padding:14px clamp(16px,4vw,40px);
    backdrop-filter:saturate(140%) blur(10px);
    background:rgba(247,249,255,.72); border-bottom:1px solid var(--border);
  }
  .brand{display:flex; align-items:center; gap:10px; font-weight:700; font-size:18px; letter-spacing:-.01em}
  .brand svg{width:28px;height:28px;border-radius:8px}
  .get{
    font-weight:600; font-size:14px; color:#fff; padding:9px 16px; border-radius:999px;
    background:var(--grad); box-shadow:0 6px 18px rgba(79,107,255,.28);
  }
  main{flex:1; display:flex; flex-direction:column; align-items:center; gap:22px;
       padding:clamp(24px,5vw,56px) 20px}
  .frame{
    background:var(--surface); border:1px solid var(--border); border-radius:var(--r-lg);
    box-shadow:var(--shadow-lift); padding:12px; max-width:min(1100px,96vw);
  }
  .frame img{
    display:block; max-width:100%; max-height:74vh; width:auto; height:auto;
    border-radius:var(--r-md); object-fit:contain;
  }
  .actions{display:flex; flex-wrap:wrap; gap:10px; justify-content:center}
  .btn{
    display:inline-flex; align-items:center; gap:8px;
    font-weight:600; font-size:14px; padding:10px 18px; border-radius:999px;
    background:var(--ink); color:#fff; border:1px solid transparent; transition:transform .08s ease, opacity .15s ease;
  }
  .btn:hover{transform:translateY(-1px)}
  .btn.ghost{background:var(--surface); color:var(--ink); border-color:var(--border)}
  .btn svg{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
  footer{
    text-align:center; padding:26px 20px 34px; color:var(--muted); font-size:13.5px; line-height:1.6;
    border-top:1px solid var(--border);
  }
  footer .tag{font-family:"Instrument Serif",Georgia,serif; font-style:italic; font-size:16px; color:var(--slate)}
  footer a{color:var(--blue); font-weight:600}
  .toast{
    position:fixed; left:50%; bottom:28px; transform:translateX(-50%) translateY(20px);
    background:var(--ink); color:#fff; font-size:13.5px; font-weight:600;
    padding:10px 18px; border-radius:999px; opacity:0; pointer-events:none;
    transition:opacity .2s ease, transform .2s ease; box-shadow:var(--shadow-lift);
  }
  .toast.show{opacity:1; transform:translateX(-50%) translateY(0)}
  @media (max-width:520px){ .brand span{display:none} }
</style>
</head>
<body>
  <header class="nav">
    <a class="brand" href="${SITE}">
      <svg viewBox="0 0 64 64" fill="none" aria-hidden="true">
        <defs>
          <linearGradient id="t" x1="32" y1="0" x2="32" y2="64" gradientUnits="userSpaceOnUse">
            <stop stop-color="#161E38"/><stop offset="1" stop-color="#070A12"/></linearGradient>
          <linearGradient id="b" x1="16" y1="16" x2="48" y2="48" gradientUnits="userSpaceOnUse">
            <stop stop-color="#4F6BFF"/><stop offset="1" stop-color="#8B5CF6"/></linearGradient>
        </defs>
        <rect width="64" height="64" rx="15" fill="url(#t)"/>
        <g stroke-width="4.4" stroke-linecap="round">
          <path d="M32 14 L38.93 36" stroke="#FF8A3D"/>
          <path d="M47.59 23 L32 40" stroke="url(#b)"/>
          <path d="M47.59 41 L25.07 36" stroke="url(#b)"/>
          <path d="M32 50 L25.07 28" stroke="url(#b)"/>
          <path d="M16.41 41 L32 24" stroke="url(#b)"/>
          <path d="M16.41 23 L38.93 28" stroke="url(#b)"/>
        </g>
      </svg>
      <span>SwiftShot</span>
    </a>
    <a class="get" href="${SITE}">Get SwiftShot</a>
  </header>

  <main>
    <div class="frame"><img src="${rawURL}" alt="Screenshot shared with SwiftShot"></div>
    <div class="actions">
      <a class="btn" href="${rawURL}?download=1">
        <svg viewBox="0 0 24 24"><path d="M12 4v10m0 0l-4-4m4 4l4-4M5 19h14"/></svg> Download
      </a>
      <button class="btn ghost" onclick="copyLink()">
        <svg viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15h-.5A1.5 1.5 0 0 1 3 13.5v-9A1.5 1.5 0 0 1 4.5 3h9A1.5 1.5 0 0 1 15 4.5V5"/></svg> Copy link
      </button>
      <a class="btn ghost" href="${rawURL}" target="_blank" rel="noopener">
        <svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h6"/></svg> Open original
      </a>
    </div>
  </main>

  <footer>
    <div class="tag">Capture, mark up, and share before the thought disappears.</div>
    <div style="margin-top:6px">Shared with <a href="${SITE}">SwiftShot</a> · native macOS screenshots with markup &amp; on-device OCR.</div>
  </footer>

  <div class="toast" id="toast">Link copied</div>
  <script>
    function copyLink(){
      navigator.clipboard.writeText('${pageURL}').then(function(){
        var t=document.getElementById('toast'); t.classList.add('show');
        setTimeout(function(){t.classList.remove('show')},1600);
      });
    }
  </script>
</body>
</html>`;
}

function notFound() {
  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found · SwiftShot</title>
<style>body{font-family:-apple-system,"Inter",sans-serif;background:#F7F9FF;color:#070A12;
display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;gap:10px;margin:0}
a{color:#4F6BFF;font-weight:600;text-decoration:none}h1{font-size:22px}p{color:#7B879D}</style></head>
<body><h1>This screenshot isn’t here</h1><p>It may have expired or the link is wrong.</p>
<a href="${SITE}">← SwiftShot</a></body></html>`;
  return new Response(html, { status: 404, headers: { "content-type": "text/html; charset=utf-8" } });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function randomToken(len = 6) {
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  let s = "";
  for (let i = 0; i < len; i++) s += TOKEN_ALPHABET[bytes[i] % TOKEN_ALPHABET.length];
  return s;
}

function mimeFromName(name = "") {
  const ext = name.slice(name.lastIndexOf(".") + 1).toLowerCase();
  return { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
           webp: "image/webp", heic: "image/heic" }[ext] || "application/octet-stream";
}

function extFromType(t = "") {
  return { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
           "image/webp": "webp", "image/heic": "heic" }[t] || "png";
}

// Named export so the viewer can be rendered/tested outside the Worker runtime.
// Harmless to Cloudflare (only `default.fetch` is invoked).
export { viewerHTML };
