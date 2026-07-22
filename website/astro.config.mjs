// Standalone marketing site for autorota, served at https://fongo.uk/autorota
// by a Cloudflare Worker (static assets) on the zone route `fongo.uk/autorota*`.
// `outDir` nests the build under dist/autorota so the Worker's 1:1 path→asset
// mapping lines up with the route prefix (Astro's `base` only prefixes URLs).
import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://fongo.uk",
  base: "/autorota",
  outDir: "./dist/autorota",
  trailingSlash: "ignore",
});
