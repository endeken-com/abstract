# Corners and borders

Abstract draws every corner and border from one small scale, so a field, a card and the
window around them look like they belong together. The values live in
`Abstract/Theme/Typography.swift` (`Radius`, `Stroke`); the shared pieces that use them are in
`Abstract/Components` (`btFieldChrome`, `btField()`, `BTTextEditor`, `btPicker()`, `btCard`,
`btRaised`, the button styles).

## Corners

A corner is chosen by what the thing is, not by its size.

| Role | Radius | What gets it |
|---|---|---|
| `Radius.mark` | 4 | Swatches, dots, tags and badges, and buttons smaller than 20 pt, like a tab's close button |
| `Radius.control` | 8 | Fields, buttons, pickers, editors, code areas, chips and list rows |
| `Radius.card` | 12 | Grouped sections and panels |
| `Radius.sheet` | 16 | What floats over the window: Settings, the palette, popovers, toasts and the composer |

A shape inside another keeps their edges parallel by subtracting the gap instead of picking a
new number: the composer's buttons sit 8 pt inside a `sheet` corner, so they get `sheet − 8`,
which is `control`. An app icon tile scales its corner with its size (`IconTile`), like the
system's icons.

### Why these values

They are the values the app already used most, so most screens barely move:

- **8 for controls.** Before this, controls were drawn at 6, 7, 8, 9 and 10. 8 was already
  the most used token (`Radius.md`, 18 uses) and the icon button's radius; the many literal
  6s and 7s (list rows, hover washes, small buttons) move by 1–2 pt, and fields (10) and
  regular buttons (9) by 1–2 pt the other way.
- **12 for cards.** macOS draws a grouped `Form`'s sections, which most of Settings is, at
  about 12 pt; measured on screen, their corners match the Usage cards' 12 pt within a pixel.
  `btCard`, Usage and the plugin gallery already used 12; Project Settings' cards move from 10.
- **16 for sheets.** The palette, `btRaised` and the question card already used 16; Settings
  moves from 14 and the toast from 12. The composer moves from 22: it floats over the
  transcript like a sheet, and its buttons then land on the control radius.
- **4 for marks.** Small things were drawn at 2, 2.5, 2.6, 3, 4 and 5; 4 was the most common.

## Borders

| Role | Width | Colour | What gets it |
|---|---|---|---|
| `Stroke.hairline` | 0.5 | `btBorder` | Dividers (`Hairline`), and the resting outline of a surface: a raised panel, an avatar, a swatch |
| `Stroke.emphasis` | 1 | `btFieldBorder` at rest; `btFieldBorderFocused`, `btBorderStrong` or the accent for focus and selection | A control's own outline (fields, secondary buttons, pickers, the composer), and focus or selection |
| `Stroke.glyph` | 1.2 | the glyph's colour | The lines of an icon drawn in code, or of a chart |

Focus and selection change a border's colour, never its width, so nothing shifts when you
click into a field. A control keeps a 1 pt outline at rest because it has to read as
something you can click or type into; a surface's hairline only separates it from what is
behind it.

## Border, fill, or neither

- **A control** (field, editor, picker, secondary button) gets a fill and a 1 pt outline. Use
  `btField()`, `BTTextField`, `BTTextEditor` or `btFieldChrome` for text, and `btPicker()` for
  a menu picker. Text in a field reads from the left, even in a form row whose controls sit
  flush right. A multi-line box shows its scroller only while it scrolls, so a scroll bar never
  sits inside its border.
- **A card** (a grouped section or panel) gets a fill and no outline, the way the grouped
  `Form` draws its sections: `btCard()`. The danger zone in Project Settings is the one card
  with an outline, because its red edge is the warning. No card sits inside another.
- **A raised panel** (Settings, the palette, popovers, toasts) floats over the
  window: a raised fill, a hairline and a neutral shadow, `btRaised()`.
- **Everything else** gets neither. The page, the sidebar, list columns and rows are unboxed;
  a row shows only a hover or selection wash in the control shape. A list column beside a
  form is square and runs edge to edge against its dividers, like Settings' own sidebar.

## The guard

`scripts/check-shapes.sh` fails when Swift code outside `Abstract/Theme` and
`Abstract/Components` writes a corner radius or stroke width as a number
(`cornerRadius: 6`, `lineWidth: 0.5`, `.btRaised(radius: 14)`). CI runs it on every pull
request, with its self-test (`scripts/tests/check-shapes-test.sh`). If a new role is truly
needed, add it to the scale and to this page instead of writing the number in place.
