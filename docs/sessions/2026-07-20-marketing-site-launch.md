# Session log — standalone marketing site launched at fongo.uk/autorota

**Date:** 2026-07-20
**Scope:** Built and deployed a standalone marketing website for autorota (`website/`), served at https://fongo.uk/autorota by a Cloudflare Worker route that shadows the personal site's Pages deployment. Removed the old markdown pages from paper_web and left its projects-page card as the only relay.

## Architecture decision

The requirement: the app's site must be its own project — own build, own visual identity, own deploy cadence — while living at `fongo.uk/autorota` on the same domain as the personal Astro site (paper_web, Cloudflare Pages git-integration).

Chosen shape:

- **Astro 5 static project in `website/`** with `base: '/autorota'` and `outDir: './dist/autorota'`. Astro's `base` only prefixes URLs, it does not nest output — nesting the outDir makes the Worker's 1:1 path→asset mapping line up with the route prefix.
- **Assets-only Cloudflare Worker** (`autorota-web`, no `main` script) with `assets.directory: './dist'`, `not_found_handling: '404-page'`, and zone route **`fongo.uk/autorota*`**. Worker zone routes take precedence over the Pages custom domain for matching paths; everything else on fongo.uk still serves from Pages.
- Cutover sequenced so the App Store Connect URLs (`/autorota`, `/autorota/support`, `/autorota/privacy`) could never 404: Worker deployed and curl-proven to intercept **before** paper_web's shadow copies were removed.

## What was done

### 1. Project scaffold (`website/`)
Replaced the stale content-pack markdown (index/support/privacy/structure.json) with a full Astro project: `astro.config.mjs`, `wrangler.jsonc`, strict tsconfig, own `.gitignore`. Assets copied in: app icon SVG (also favicon + 180px apple-touch-icon via `sips`), 6 iPhone + 6 iPad App Store screenshots plus `first-shot-clear.png` from `design/appstore-preview/`. Support + privacy markdown ported verbatim from paper_web's live copies (the most current versions) into a `docs` content collection.

### 2. Landing page design
Apple-product-gallery energy on autorota's own identity — palette derived from the app icon (`#2563EB` blue, watch-face white, hairline grays `#E3E7EC`), system SF type stack, 1100px measure, alternating white/`#F5F6F8` sections. Sections: hero (overlapped iPad-behind/iPhone-front composition, caption bands cropped via `clip-path`), 3-step How-it-works whose third card **animates a mini rota assembling itself** on scroll (the signature moment, echoing "built in a tap"), four feature sections with cropped `DeviceShot`s, a 12-screenshot scroll-snap gallery rail, a dark privacy panel ("No accounts. No tracking. Nothing collected."), audience chip strip, closing CTA with the pocket-watch logo art, branded 404 ("Off shift."). JS footprint: one 15-line IntersectionObserver reveal script; content fully visible without JS; `prefers-reduced-motion` disables all motion. `AppStoreBadge` renders a "Coming soon" pill until `APP_STORE_URL` in `src/consts.ts` is set.

### 3. Visual QA bugs found via headless-Chrome screenshots
- **Distorted hero devices:** global CSS had `img { max-width: 100% }` without `height: auto` — the `height` attribute kept its pixel value while width clamped. Classic; fixed globally.
- **Mobile horizontal overflow:** the "Coming soon" pill was `inline-flex`, so its text run became a nowrap flex item at max-content width (~440px), stretching the layout viewport. Switched to `inline-block`.
- Two false alarms worth remembering: headless Chrome `--window-size=390` screenshots clip as if overflowing even when `scrollWidth` is clean (verify with puppeteer viewport + `getBoundingClientRect` sweep before touching CSS), and full-page captures ghost `.reveal` sections because the site's `scroll-behavior: smooth` cancels scripted scroll passes — scroll with `behavior: 'instant'` in test scripts.

### 4. Deploy + interception proof
`npm run deploy` (clean build + `wrangler deploy`) after an interactive `wrangler login` (old token was R2-scoped and expired). The assets-only Worker accepted the zone route without a passthrough script. Live curl matrix: `/autorota/` 200 with new title, `/autorota/support` + `/privacy/` 200 new content, garbage path → branded 404, `fongo.uk/` and `/projects` untouched Pages.

### 5. paper_web cleanup (commit `283589c`)
Deleted `src/pages/autorota/`, `src/data/autorota/`, untracked `autorota_drafting/`; removed the `autorota` collection from `content.config.ts`. Projects-page card (`project_list.json`) keeps linking to `/autorota` — same-domain, now answered by the Worker. Built clean (10 pages), pushed after the interception proof passed.

## Key takeaways

1. **Worker zone route + nested outDir is the clean way to mount a separate site on a subpath** of a Pages-served domain. No routing glue in either project; each deploys independently.
2. **`base` in Astro prefixes URLs but does not nest build output** — pairing it with a nested `outDir` is what makes subpath asset serving work.
3. **Sequence subpath cutovers so the failure mode is "old content still serves", never 404** — deploy the shadowing Worker first, prove interception with content markers (not just status codes), then remove the original pages.

## Next steps (planned with Oliver)

1. **New imagery for the website.** Current set is only the 12 App Store screenshots + logo art — built for store listing, not web marketing. Session to chat through what image types are missing (lifestyle/context shots, hero-grade renders without caption bands, feature close-ups, device frames at web-friendly crops) and where the marketing gaps are.
2. **Colour + design blending.** Tune the palette and layout against one or two other big-site inspirations to blend with the current Apple direction, rather than reading purely Apple-derived.
3. **Personal touch.** Hone how Oliver's own voice/energy for the app comes through the web design — the site should carry the app's intended personality, not just a competent template of the genre.
4. **UX fine-tuning.** Transitions and small CSS micro-interactions (hover/press feedback, section motion) once the visual direction from 1–3 settles.
