# Paperhue app icon

`make_icons.py` is the single source of the Paperhue icon on every platform; `paperhue-1024.png` is its master render.
To regenerate, run `python shared/brand/make_icons.py <new folder>` (needs only Pillow; the same Pillow version writes byte-identical files).
Then copy `windows/*` to `python/src/ulani_epaper/assets/`, the PNGs of `macos/AppIcon.appiconset/` to `apple/Paperhue/Paperhue/Assets.xcassets/AppIcon.appiconset/` and `paperhue-1024.png` to this folder.
