# Capsule — logo pack

Two-tone capsule mark: one half solid Indigo, one half indigo glass, a bright
core dot at the seam. Pill rotated -24 degrees. Palette: "Graphite & Indigo".

## Colors

| Token          | Light     | Dark      |
|----------------|-----------|-----------|
| Accent (indigo)| #5856D6   | #5E5CE6   |
| Glass half     | #DBDAF7   | #312F63   |
| Core dot       | #FFFFFF   | #FFFFFF   |
| Wordmark text  | #1D1D1F   | #F5F5F7   |

"light" = for light backgrounds. "dark" = for dark backgrounds.
All PNGs have transparent backgrounds.

## Contents

- svg/ ................. vector sources (edit these, everything else is derived)
    - capsule-icon-{light,dark}.svg          square 512 viewBox icon
    - capsule-wordmark-{light,dark}.svg      horizontal lockup (system font stack;
                                             renders with SF Pro on a Mac — convert
                                             text to outlines before print use)
    - capsule-menubar-template.svg           alpha-only mono mark for the menu bar
- png/light/ ........... capsule-light-{16..1024}.png
- png/dark/ ............ capsule-dark-{16..1024}.png
- png/menubar-template/  16 / 18 pt + @2x, name them *Template.png in Xcode so
                         AppKit treats them as template images
- iconset/ ............. Capsule-{light,dark}.iconset — ready for iconutil

## Make a .icns on your Mac

    iconutil -c icns iconset/Capsule-light.iconset -o Capsule.icns

For the app, prefer an asset catalog AppIcon with the light set as "Any"
and the dark set as the Dark appearance variant (macOS 26 supports
appearance-aware app icons).

## Usage rules (from the plan, section 6.7)

1. Indigo is brand/interactive only — never a container state color.
2. Keep the mark on flat surfaces; do not place it over busy imagery.
3. Menu bar uses the template mark only; the OS handles tinting.
