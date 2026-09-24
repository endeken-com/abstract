# Icons

Abstract's own icon assets go here, replacing the placeholders that
`create-tauri-app` generated. Drop in:

- `icon.icns` — macOS bundle icon
- `icon.png` — 1024×1024 source PNG
- `32x32.png`, `128x128.png`, `128x128@2x.png` — generated sizes
- `icon.ico` — Windows (unused today, but the bundler config lists it)

With a 1024px PNG or the source SVG in hand, the whole set regenerates with:

    bun tauri icon path/to/abstract-1024.png

The tray uses the app's default window icon, so replacing these updates the
tray too.
