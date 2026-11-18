---
name: icon-images
description: Generate, compare or regenerate Perch's icon artwork (the menu bar robin, the title bar buttons, the app icon) with image models through OpenRouter, then trace or install the result. Use when asked to explore, refine, redo or vary Perch's icons or other branding images.
---

# Perch icon images

Read `docs/branding/README.md` first: it says where every icon lives, how the
current ones were made, and the prompts used.

## Generate

```sh
export OPENROUTER_API_KEY=...   # from the user's secrets; never print or commit it
scripts/generate-images.py --prompt-file <brief.txt> [--ref <image>]... [--model <id>]... [--takes N] --out .build/generated-images/<round>
scripts/generate-images.py --list   # image models available now
```

- It asks three strong models in parallel by default (OpenAI and Google) and
  prints each one's cost; a round is usually under a dollar. Spending is
  pre-approved for icon work in this project, but say what a round cost.
- Attach references (`--ref`) for anything iterative: crop the favourite out
  of a sheet first (`uv run --with pillow python` for cropping; `sips` crops
  centred and ignores offsets). Name what to keep and what to change.
- Ask for a sheet (several variants in a grid) to explore, one full-bleed
  square with "no rounded corners, no border, no shadow" for final app icon
  art, and pure black-on-white glyphs, side by side, for menu bar shapes.
- Briefs that worked: say who the app is for and its character (swift,
  lightweight, unobtrusive), the subject and its pose, the exact layout of
  the sheet, the constraints (legible at 16 px, no text, no fine detail), and
  "no text or letters anywhere".

## Show and choose

Put rounds on one comparison page (an Artifact), newest first, with the
images as files beside the page. Say plainly which work best and why; the
user picks.

## Install the choice

- **Menu bar or button glyph:** trace it as vector paths on the 24 unit grid
  in `MenuBarGlyph.Shape` (images are never shipped as glyphs). Check with
  `scripts/glyph-preview.sh`, especially the real-size row.
- **App icon:** save the full-bleed art as `docs/branding/app-icon-art.png`,
  run `swift generate_icon.swift`, and look at the 32 and 256 pixel sizes.
- Keep the chosen reference in `docs/branding/reference/` and update the
  README's record of how it was made.
