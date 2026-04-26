# SuperBarato.cl — Logo Assets

## Files
- `logo-horizontal.svg` — full logo for light backgrounds
- `logo-horizontal-dark.svg` — full logo for dark backgrounds
- `cart-mark.svg` — standalone cart mark (icon only)
- `favicon.svg` — favicon for 32px+ (white tile, full cart detail)
- `favicon-16.svg` — simplified favicon optimized for 16px tab rendering

## Brand colors
| Token | Hex | Use |
|---|---|---|
| Ink | `#0A0A0A` | "Super", cart body, default text |
| Magenta | `#FF1D6E` | "Barato", accents, stripes |
| TLD muted | `#A0A0A0` | ".cl" on light bg |
| TLD muted (dark) | `#888888` | ".cl" on dark bg |

## Type
- **Wordmark:** Archivo Black, italic (Google Fonts: `Archivo` weight 900, italic)
- **TLD:** Archivo, italic disabled, weight 600
- **Letter-spacing:** -1.4px on the wordmark

## Usage
- Min logo height: 32px
- Clear space: half the cart height on all sides
- Favicon: serve `favicon.svg` as the canonical favicon and `favicon-16.svg` as the legacy 16/32 ico fallback (rasterize via your build step)

## HTML snippet
```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="alternate icon" href="/favicon.ico">
```
