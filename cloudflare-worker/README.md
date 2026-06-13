# SwiftShot Cloudflare Worker

One Worker serves both hostnames for the cloud-sharing feature:

| Host | Method | Behavior |
|------|--------|----------|
| `up.swiftshot.online`  | `POST` | Authenticated upload to R2 → returns `{"url":"https://i.swiftshot.online/<token>"}` |
| `i.swiftshot.online/<token>`        | `GET` | **Branded viewer page** (browser navigation / link unfurls) |
| `i.swiftshot.online/<token>` (as `<img>`) | `GET` | Raw image bytes (content-negotiated: `Accept: image/*` without `text/html`) |
| `i.swiftshot.online/<token>/raw` or `?raw` | `GET` | Raw image bytes, always |
| `i.swiftshot.online/<token>/raw?download=1` | `GET` | Raw bytes with `Content-Disposition: attachment` |

The viewer (`worker.js → viewerHTML`) matches the marketing site theme (canvas `#F7F9FF`,
ink `#070A12`, blue→violet→orange gradient, Inter + Instrument Serif, shutter-burst logo)
and includes Open Graph / Twitter-card tags so links unfurl with an image preview.

## Worker config (Settings)
- **Bindings → R2 bucket**: variable `BUCKET` → bucket `screenshots`
- **Variables**: `PUBLIC_BASE` = `https://i.swiftshot.online`
- **Secret**: `UPLOAD_TOKEN` = the bearer token the app sends

## Deploy / update
1. Workers & Pages → `cleanshot-upload` → **Edit code** → paste `worker.js` → **Deploy**.
2. **Move `i.swiftshot.online` to the Worker** (required — a hostname can't be both an R2
   custom domain and a Worker route):
   - R2 → bucket `screenshots` → Settings → **Custom Domains** → **remove** `i.swiftshot.online`.
   - Worker → **Domains** → **Add → Custom Domain** → `i.swiftshot.online` (keep `up.` too).
3. Confirm the three bindings/vars above exist, then redeploy.

## Test
- Open `https://i.swiftshot.online/<token>` in a browser → branded viewer page.
- `https://i.swiftshot.online/<token>/raw` → the bare image.
- Paste a link into Slack/Discord → image preview via Open Graph.
