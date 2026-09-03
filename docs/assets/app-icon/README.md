# App icon — sources

Owner pick 2026-09-03: **direction A · Prompt** (`direction-a-prompt.svg`) — a terminal caret in off-white, the block cursor lit amber: a terminal waiting on you, in the product's own terms (graphite field, one amber lamp; PRD §7.15). `direction-b-monogram.svg` and `direction-c-cursor.svg` were considered and not chosen; `directions-sheet.svg` is the comparison sheet the pick was made from (the published comparison: https://claude.ai/code/artifact/a644a532-591f-41ed-94dc-bd1f2f30df65).

What ships is `apps/ios/Tavi/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, 1024², opaque sRGB, drawn from the same numbers as the SVG with CoreGraphics (`scripts/render-app-icon.swift`); iOS derives the dark and tinted appearances from it.
