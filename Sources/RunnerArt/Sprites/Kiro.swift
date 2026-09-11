// Kiro — fan pixel adaptation of the Kiro ghost mascot, for PERSONAL USE ONLY.
// Kiro © Amazon Web Services. Not affiliated with or endorsed by Amazon Web Services. Do not redistribute or export.
//
// References (checked 2026-09-11):
//   https://kiro.dev/icon.svg (rendered at 512 px) — canonical mark: white ghost on a #9046FF rounded square;
//   narrow dome leaning right, straight sides, left side bulging out low, two-lobed hem (bigger left lobe,
//   smaller right lobe), two black vertical oval eyes right of centre at the dome's mid-height.
//   https://kiro.dev Open Graph image — the same ghost glyph next to the "Kiro" wordmark.
//   https://www.geekwire.com/2025/amazons-surprise-indie-hit-kiro-launches-broadly-in-bid-to-reshape-ai-powered-software-development/
//   — the mascot is a ghost named Kiro.
// Drawn by measuring the icon ghost's edge row by row onto a 16×17 grid, with a 1-cell #9046FF outline.
// White body, black 2×3 eyes, #9046FF outline (so it reads on light menu bars); no purple square background.
// 18×18 canvas, ghost 16 wide × 17 rows (18 while a lobe trails). 6-frame float: 1-row bob, the hem lobes ripple
// (left and right take turns hanging lower); the dome and eyes never change; five frames touch row 17.

import GoRunnerCore

extension RunnerArtCatalog {
    /// Kiro (personal use only): white ghost with black eyes and a #9046FF outline, floating with a rippling hem.
    /// 6 frames, 18×18 cells.
    static let kiro = PixelSprite(
        id: "kiro",
        names: ["ko": "키로", "en": "Kiro"],
        palette: [
            "o": 0x9046FFFF, // outline — Kiro purple #9046FF
            "w": 0xFFFFFFFF, // ghost
            "k": 0x000000FF, // eyes
        ],
        frames: [
            [ // 0: rest: hem even on the ground row
                "..................",
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....owwwwwowwwo...",
                ".....ooooo.ooo....",
            ],
            [ // 1: rest: right lobe tucks, left lobe hangs lower
                "..................",
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....owwwwwooooo...",
                ".....ooooo........",
            ],
            [ // 2: float up: left lobe trails down to the ground row
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....owwwwwowwwo...",
                ".....owwwo.ooo....",
                "......ooo.........",
            ],
            [ // 3: float: hem even, one row off the ground
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....owwwwwowwwo...",
                ".....ooooo.ooo....",
                "..................",
            ],
            [ // 4: float: right lobe trails down to the ground row
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....owwwwwowwwo...",
                ".....ooooo.owo....",
                "............o.....",
            ],
            [ // 5: settle: left lobe tucks, right lobe hangs lower
                "..................",
                ".......oooooo.....",
                ".....oowwwwwwoo...",
                "....owwwwwwwwwwo..",
                "....owwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwkkwwkkwwo.",
                "...owwwwwwwwwwwwo.",
                "...owwwwwwwwwwwwo.",
                "..owwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                ".owwwwwwwwwwwwwwo.",
                "..oowwwwwwwwwwwwo.",
                "...owwwwwwwwwwwo..",
                "....ooooooowwwo...",
                "...........ooo....",
            ],
        ],
        isTemplate: false,
        credit: "Kiro © Amazon Web Services — fan pixel adaptation for personal use. Not affiliated with or endorsed by Amazon Web Services.",
        license: "Amazon Web Services — personal use only",
        isBrandInspired: true,
        tags: ["personal-only", "brand-exact"]
    )
}
