# River app icon

The user selected **G — 유리 속의 바다 (Sea inside glass)** on 2026-10-22 with “g ㄱㄱ”. The three streams of amber, teal and lilac light meet in a broad glass ocean: our work comes together into the software we build.

## Authorship and files

- Claude supplied the original G art direction and image prompt, reproduced below.
- The built-in imagegen tool rendered the selected G concept, then prepared the transparent exterior while preserving its appearance. This is generated raster artwork, not a Claude-drawn vector.
- Codex integrated the selected image and exported the native icon sizes using macOS `sips` and `iconutil`.
- `River-G-master.png` is the transparent production master. SHA-256: `5994ad5d8d6f1a0d9f3a757fae912bf6088729a4d14c94b7e80879c602d15ba7`.
- `../AppIcon.png` is the 1024×1024 PNG export used by the README.
- `../AppIcon.icns` contains the 16/32/128/256/512-point icon sizes at 1× and 2×. The app bundle and Welcome screen use this file.
- Original selected G concept SHA-256: `62bfed4a5689c4776895fe92128d970e6bea369729cb3155436c1139a908970e`. The rejected A–F and unselected H–L remain historical exploration artifacts.

Rebuild the exports on macOS:

```sh
python3 scripts/build_macos_icon.py
python3 scripts/build_macos.py
open build/macos/River.app
```

The visible app name is River. Existing Swift/Rust target names, bundle identifier and application data paths retain their current identifiers so the branding update does not move existing data.

## Original G generation prompt — built-in imagegen

```text
Use case: logo-brand. A new, original, standalone native macOS app icon for an app named River. Render one centered, front-facing rounded-square tile occupying about 84% of a square canvas, with a small clean neutral light-gray margin. The tile is deep slate charcoal with a subtle vertical gradient. On it rests a single thick, polished optical-glass object: a wide, soft-edged oval lens, slightly domed, filling the lower two-thirds of the tile. It reads as a calm, heavy paperweight. Three slender threads of colored light, warm amber, clear teal, and soft lilac, enter the top of the glass from slightly different angles. Inside the glass they diffuse and blend into one luminous aqua core, so the shared body is clearly the hero and much larger than any incoming thread. Lighting: soft top-left key light, crisp specular rim along the upper glass edge, gentle caustic glow cast onto the tile below. Premium macOS Big Sur-style depth, restrained and calm. Avoid: water droplet shapes, waves, trees, tridents, letters, Git nodes or branch diagrams, petals, text, numbers, logos, watermark, UI, hardware, multiple icons.
```

## Transparent-background preparation prompt — built-in imagegen

```text
Edit the attached APPROVED River macOS app icon. Use case: background-extraction. The user selected this exact G icon. Remove ONLY the pale gray/white rectangular background OUTSIDE the dark rounded-square app tile. Deliver a square PNG with a genuinely transparent alpha background outside the rounded-square tile and around its corners. Preserve the approved dark charcoal rounded-square tile, its border, the thick glass lens/pool, the three amber/teal/lilac streams of light, aqua core, caustics, reflections, highlights, lighting, composition, relative sizes and exact visual identity. Keep the tile centered at its current scale with a modest transparent margin. Preserve the tile's fully opaque dark surface and all its internal glass/lighting; the glass INSIDE the dark tile must not be cut out or made transparent. Keep a very subtle soft exterior shadow if it can be rendered with transparent alpha. Do not redraw or restyle, do not add new objects, no words, letters, logos or watermark. This is production background preparation for the existing icon, not a new design. Preserve the original image's appearance as closely as possible.
```
