# Cirrus brand

**Name:** Cirrus Video Compressor (short: Cirrus). Never all caps in running text.
**Tagline:** Less weight. Same picture.
**Owner line:** © 2026 Cirrus. The product is credited to no person.

## Idea: Convergence
Cirrus clouds are thin, high and fast: almost no mass. The mark is six cirrus streaks crossing a
high-altitude dawn sky and converging on one bright point. Many streaks, one point: a lot of material
becomes something small and luminous. No cloud silhouette is ever used (that belongs to cloud storage).
The four directions explored and the reasons for this choice are in `identity-exploration.html`.

## Icon
`Scripts/make_icon.swift` draws it (macOS grid: 824 pt body, 185 pt corners). Sizes ≤ 32 px use a simplified
3-streak drawing. Source of truth: the script, not the PNGs.

## Colour
| token | light | dark | use |
|---|---|---|---|
| Sky (accent) | #3A6AAE | #8FB6E8 | buttons, selection, progress |
| Dawn | #D98E62 | #F0B28C | arrival only: convergence point, "saved" figures |
| Altitude | #14294D | | icon/sky gradient top, About band |
| Haze | #BFD3EA | | sky gradient |
| Dawn (fixed) | #F2C2A0 | | sky gradient horizon |

Semantic colours (warnings, errors, success) stay the system's own. Dawn is never a warning colour.

## Type
In the app: SF Pro (system), Dynamic Type, tabular figures for sizes and percentages. Display text
(drop zone, About, progress %) uses SF Pro Light/Ultralight. Marketing: Hanken Grotesk Light (OFL) for
display, SF Pro / Instrument Sans for text.

## Motion
* Waiting for a drop: streaks drift slowly; on drag-over they settle and the point warms.
* Compressing: streaks draw toward the point as progress advances (`ConvergenceProgress`).
* Done: a settled line with a Dawn point next to the result.
All motion respects Reduce Motion.
