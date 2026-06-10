# rota app icon — design explorations

Core design: minimalist open-face pocket watch (winding crown, two-ring case, faint minute-dot track, chapter ring, hour notches) with the lowercase wordmark "rota", where the "o" is fused with an 8-tooth gear.

Milestone reference: `../../rota-app-icon-milestone-1.svg` (cobalt #2563EB original).

## Structure

```
app-icon/
  <icon_name>/            one folder per icon concept (currently: pocketwatch)
    colors/
      <family>/           one folder per color family
        rota-icon-<family>.svg          base icon
        rota-icon-<family>-<shade>.svg  shade variants (e.g. -dark, -light)
    fonts/                letterform variants, added as we iterate
      rota-icon-<font>.svg              (e.g. -squared, -thin)
```

## Icon concepts

- `pocketwatch/` — the original minimalist white-dial design
- `opalescent-pocketwatch/` — whimsical riff: layered color waves fill the dial, white wordmark, deep blue case (#1A5FD6) with colored pinstripe, azure (#36A3FF) as the anchoring mid-wave in every palette. Base inspiration saved as `opalescent-pocketwatch/rota-icon-opalescent-base.svg`. Palettes: `sunrise` (coral/orange, the base), `lagoon` (teal/mint), `dusk` (violet/pink); professional set: `harbor` (tonal deep blues, navy case, silver pinstripe), `graphite` (slate/charcoal, brass pinstripe)

Every SVG has a matching 1024×1024 PNG beside it.

## Color families (pocketwatch)

| Folder | Color | Hex |
|---|---|---|
| `pocketwatch/colors/azure/` | Azure | `#0A84FF` |
| `pocketwatch/colors/cornflower/` | Cornflower | `#5B8DEF` |
| `pocketwatch/colors/denim/` | Denim | `#4E7CC2` |

Shared grays: crown/gear `#8794A3`, crown ridges `#5F6B7A`, hour notches `#D2D8DF`, minute track `#DEE3E9`, chapter ring `#E9ECF0`, background border `#E3E7EC`.
