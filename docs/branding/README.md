# Perch's icons

Perch's mark is a robin, side on and facing left, with an orange breast: in
flight while nothing is perched, settled on a branch while something is. It
faces left because the perch button sits at the right of a title bar, so the
bird looks along the bar towards it.

| What | Where it lives | How it is made |
|---|---|---|
| Menu bar icon, both states | `Sources/MenuBarGlyph.swift` (`MenuBarGlyph.Shape`) | Vector paths, drawn by the app |
| Title bar buttons | `Sources/PinBadges.swift` (`BadgeView.draw`) | The same robin on a circle |
| App icon | `docs/branding/app-icon-art.png` → `Resources/AppIcon.icns` | `swift generate_icon.swift` |
| References | `docs/branding/reference/` | The images the shapes were traced from |

## The robin glyph

The two birds are path data on a 24 unit grid, y pointing down, written like
SVG (`M`, `L`, `C`, `Z`, absolute coordinates only). Each has:

- `outline`: the whole bird, filled in the menu bar's ink.
- `breast`: the orange patch, filled in `MenuBarGlyph.breast`.
- `cut`: a line cut out of the bird (neither bird uses one now; the perched
  bird's gaps are spaces between its pieces).
- `eye`: a small circle, cut out.
- `feet`: the perched bird's legs and branch, stroked.

To change a shape:

1. Run `scripts/glyph-preview.sh`. It renders the shapes large on the grid,
   at real size in light and dark menu bars, and on the title bar buttons, to
   `.build/glyph-preview/glyphs.png`, and writes `flying.svg` and
   `perched.svg` beside it.
2. Edit either the path data in `MenuBarGlyph.Shape` directly, or the SVG in
   a vector editor (keep the 24 by 24 view box and absolute coordinates; the
   reader takes `M`, `L`, `C` and `Z` only), then paste the `d` attribute
   back into `MenuBarGlyph.Shape`.
3. Run the preview again, and check the real-size row: the bird has to read
   at 16 points.

The original is `reference/menubar-robin.png`: Google Gemini Nano Banana 2.1's
"orange breast" row from the third round of exploration below, facing right
as it was generated. Its outlines were fitted with smoothed contours
simplified to a few dozen points, then mirrored (x becomes 24 − x).

## The app icon

`app-icon-art.png` is a full-bleed square with no rounded corners.
`generate_icon.swift` scales it onto Apple's macOS icon grid (an 824 pixel
rounded square centred on 1024), adds the soft shadow macOS icons carry and
writes `Resources/AppIcon.icns`. To change the icon, replace the art and run:

```sh
swift generate_icon.swift
```

The design is Google Gemini 3 Pro Image's own variation from round four
(below), `reference/app-icon-concept.jpg`: a big robin gripping the title bar
of a window that comes in from the lower right, on orange fading to teal. The
final art was redrawn from it, full bleed, by OpenAI GPT-5.4 Image 2, with:

> The attached image is an app icon design I've chosen. Recreate it as final
> production artwork: one square image, the artwork filling the whole square
> edge to edge, with NO rounded corners, NO border, NO drop shadow and nothing
> outside the art (I will apply the macOS rounded-square mask myself, which
> trims about 10% from each edge, so keep the bird's beak, head and tail clear
> of the outer tenth). Keep the same design exactly: [the design, described].
> Crisp edges, bold shapes, strong contrast, readable at 32 pixels. No text.

## Making more

`scripts/generate-images.py` sends a brief, with optional reference images,
to several image models through OpenRouter at once and saves what comes back:

```sh
export OPENROUTER_API_KEY=...
scripts/generate-images.py --prompt-file brief.txt \
    --ref docs/branding/reference/menubar-robin.png --out .build/generated-images/round4
scripts/generate-images.py --list    # the image models available now
```

It uses only the Python standard library and prints each model's cost. A
generated image is a starting point: a glyph is traced by hand into
`MenuBarGlyph.Shape`, and app icon art goes through `generate_icon.swift`.
The `icon-images` skill in `.claude/skills/` walks an agent through a round.

## How the design was chosen

Three rounds, November 2026, each sent to Google Gemini Nano Banana 2.1,
Google Gemini 3 Pro Image and OpenAI GPT-5.4 Image 2 through OpenRouter's
chat completions API (`modalities: ["image", "text"]`):

1. A broad brief: menu bar glyph pairs (in flight, perched) and app icons in
   many art styles. Spread-wing birds seen from the front did not read at
   menu bar size; side-on flight did.
2. Side-on songbirds only, in four styles.
3. The favourites attached as references, with the brief: slim and swift,
   never chubby, one touch of colour (the robin's breast); for the app icon,
   the same bird perched on an app window, gripping its top edge.
4. The first app icon (a robin on a frosted window at dusk) was too soft to
   see in the Dock. The brief: the bird large, in the top three fifths, with
   a strong outline, gripping only a macOS title bar with its traffic lights,
   not a whole window; bold shapes that read at 32 pixels.
5. The chosen design redrawn as full-bleed final art, several takes, compared
   through the real rounded-square mask at Dock size and at 32 pixels.

The glyph first chosen, OpenAI GPT-5.4 Image 2's slim robin, was too thin to
read as a bird at 16 points, in the menu bar and on the buttons. In
November 2026 it was replaced by Nano Banana's rounder robin from the same
round, turned to face left. Either way the glyph is vector paths, so it is
crisp at every size and costs nothing to draw.
