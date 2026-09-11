// Clawd — fan pixel adaptation of Claude Code's mascot, for PERSONAL USE ONLY.
// Clawd © Anthropic PBC. Not affiliated with or endorsed by Anthropic. Do not redistribute or export.
//
// Reference: glyph art in Claude Code 2.1.268 (bin/claude.exe → embedded /$bunfs/root/chunk-bdxgk81e.js, line 11),
// "default" pose rows:
//     " ▐▛███▛█"      (▛███▛█ drawn on black → the missing quadrants are the eyes)
//     "▝▜██████▀"
//     "  ▝▝ ▝▝  "
// Quadrant glyphs give a 17×5 px figure: block body, two eyes, claw stubs on both sides, four short legs in two pairs.
// This version (user request: between the flat and the tall drafts, slightly wider than tall): 19×18 canvas,
// 15×11 block body in clawd_body rgb(215,119,87), 2×2 black eyes in the upper part, 2×2 claw stubs on both sides
// just below the eyes, four 2-wide legs in two pairs. Character is 19 wide × 14 rows (13 on the down frames).
// 6-frame walk in place: contact → down → passing, then mirrored. Diagonal pairs (legs 1+3, 2+4) alternate between
// planted (3 rows) and lifted two rows off the ground; the body dips one row on the down frames and never changes shape.

import GoRunnerCore

extension RunnerArtCatalog {
    /// Clawd (personal use only): #D77757 block with black eyes and claw stubs, walking on four legs.
    /// The body is identical in every frame; only its height (1-row dip) and the legs change.
    /// 6 frames, 19×18 cells.
    static let clawd = PixelSprite(
        id: "clawd",
        names: ["ko": "클로드", "en": "Clawd"],
        palette: [
            "c": 0xD77757FF, // body — clawd_body rgb(215,119,87)
            "e": 0x000000FF, // eyes — clawd_background rgb(0,0,0)
        ],
        frames: [
            [ // 0: contact: legs 1+3 planted, 2+4 lifted high
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "...cc......cc......",
                "...cc......cc......",
            ],
            [ // 1: down: body dips, 1+3 bear the weight, 2+4 swinging down
                "...................",
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "...cc......cc......",
            ],
            [ // 2: passing: 2+4 land, 1+3 lift off
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "...cc.cc...cc.cc...",
                "......cc......cc...",
            ],
            [ // 3: contact: legs 2+4 planted, 1+3 lifted high
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "......cc......cc...",
                "......cc......cc...",
            ],
            [ // 4: down: body dips, 2+4 bear the weight, 1+3 swinging down
                "...................",
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "......cc......cc...",
            ],
            [ // 5: passing: 1+3 land, 2+4 lift off
                "...................",
                "...................",
                "...................",
                "...................",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..cceeccccccceecc..",
                "..cceeccccccceecc..",
                "ccccccccccccccccccc",
                "ccccccccccccccccccc",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "..ccccccccccccccc..",
                "...cc.cc...cc.cc...",
                "...cc.cc...cc.cc...",
                "...cc......cc......",
            ],
        ],
        isTemplate: false,
        credit: "Clawd © Anthropic PBC — fan pixel adaptation for personal use. Not affiliated with or endorsed by Anthropic.",
        license: "Anthropic — personal use only",
        isBrandInspired: true,
        tags: ["personal-only", "brand-exact"]
    )
}
