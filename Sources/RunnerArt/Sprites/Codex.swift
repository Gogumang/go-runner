// Codex — personal-use pixel adaptation of the OpenAI Codex app logo, for PERSONAL USE ONLY.
// Codex logo © OpenAI. Not affiliated with or endorsed by OpenAI. Do not redistribute or export.
//
// Reference (2026-09-11): the image the user supplied as "the Codex logo" — a 225×225 Google image thumbnail
// (gstatic), kept locally at scratchpad/refs/codex-ref.png. It shows a scalloped, eight-lobed cloud (slightly turned:
// the top lobe sits left of centre, the bottom lobe right of centre) filled with a vertical gradient from lavender
// (#ADA7FB at the top) through periwinkle (#859FFD, middle) to blue (#454EFB at the bottom), with a white terminal
// prompt ">_" drawn in rounded strokes: a chevron left of centre and an underscore level with its lower tip.
// Design: the cloud silhouette area-sampled from the reference straight onto a 16×15 grid (coverage ≥ 0.5; 15 rows
// so a 3-row hop fits the 18-row canvas), plus two 1-cell dips at the clearest lobe seams (right of the top lobe,
// left of the bottom lobe); seven gradient bands sampled row by row from the reference; the prompt in #FFFFFF as a
// 3×5 one-cell chevron and a 4-cell underscore on the chevron's bottom row, where the reference places them.
// No outline, no legs.
// 20×18 canvas. 6-frame hop in place: contact → rise → rise → apex → fall → fall.
//   contact: squashed to 18×13 (two centre columns doubled, two rows away from the prompt dropped), on row 17;
//   rise:    round 16×15, 1 then 2 rows up, the prompt trailing one row low;
//   apex:    3 rows up, prompt centred;
//   fall:    2 then 1 row up, the prompt trailing one row high, back into the squash.

import GoRunnerCore

extension RunnerArtCatalog {
    /// Codex (personal use only): the lavender-to-blue scalloped cloud with a white ">_" prompt, hopping in place.
    /// Squashes on contact; the prompt trails the bob by one row.
    /// 6 frames, 20×18 cells.
    static let codex = PixelSprite(
        id: "codex",
        names: ["ko": "코덱스", "en": "Codex"],
        palette: [
            "a": 0xAAA6FCFF, // #AAA6FC — lavender top
            "b": 0x9DA3FEFF, // #9DA3FE
            "c": 0x8EA0FEFF, // #8EA0FE
            "d": 0x7F9EFCFF, // #7F9EFC — periwinkle middle
            "e": 0x7090FCFF, // #7090FC
            "f": 0x6076FEFF, // #6076FE
            "g": 0x4E5CFDFF, // #4E5CFD — blue bottom
            "W": 0xFFFFFFFF, // ">_" prompt
        ],
        frames: [
            [ // 0: contact: squashed on the ground (18×13), bottom edge on row 17
                "....................",
                "....................",
                "....................",
                "....................",
                "....................",
                "......aaaaaa........",
                ".....aaaaaaa.aaa....",
                "....bbbbbbbbbbbbb...",
                "..cccccccccccccccc..",
                ".ccccWcccccccccccc..",
                ".dddddWddddddddddd..",
                ".ddddddWddddddddddd.",
                "..eeeeWeeeeeeeeeeee.",
                "..eeeWeeeeWWWWWeeee.",
                "..ffffffffffffffff..",
                "...ggggggggggggg....",
                "....ggg.ggggggg.....",
                "........gggggg......",
            ],
            [ // 1: rise: round again, 1 row up, glyphs trail 1 row low
                "....................",
                "....................",
                ".......aaaa.........",
                "......aaaaa.aaa.....",
                ".....bbbbbbbbbbb....",
                "....bbbbbbbbbbbbb...",
                "...cccccccccccccc...",
                "..ccccccccccccccc...",
                "..ddddWdddddddddd...",
                "..dddddWdddddddddd..",
                "...eeeeeWeeeeeeeee..",
                "...eeeeWeeeeeeeeee..",
                "...fffWfffWWWWfff...",
                "...fffffffffffff....",
                "....ggggggggggg.....",
                ".....ggg.ggggg......",
                ".........gggg.......",
                "....................",
            ],
            [ // 2: rise: 2 rows up, glyphs trail 1 row low
                "....................",
                ".......aaaa.........",
                "......aaaaa.aaa.....",
                ".....bbbbbbbbbbb....",
                "....bbbbbbbbbbbbb...",
                "...cccccccccccccc...",
                "..ccccccccccccccc...",
                "..ddddWdddddddddd...",
                "..dddddWdddddddddd..",
                "...eeeeeWeeeeeeeee..",
                "...eeeeWeeeeeeeeee..",
                "...fffWfffWWWWfff...",
                "...fffffffffffff....",
                "....ggggggggggg.....",
                ".....ggg.ggggg......",
                ".........gggg.......",
                "....................",
                "....................",
            ],
            [ // 3: apex: 3 rows up, glyphs centred
                ".......aaaa.........",
                "......aaaaa.aaa.....",
                ".....bbbbbbbbbbb....",
                "....bbbbbbbbbbbbb...",
                "...cccccccccccccc...",
                "..ccccWcccccccccc...",
                "..dddddWddddddddd...",
                "..ddddddWddddddddd..",
                "...eeeeWeeeeeeeeee..",
                "...eeeWeeeWWWWeeee..",
                "...ffffffffffffff...",
                "...fffffffffffff....",
                "....ggggggggggg.....",
                ".....ggg.ggggg......",
                ".........gggg.......",
                "....................",
                "....................",
                "....................",
            ],
            [ // 4: fall: 2 rows up, glyphs trail 1 row high
                "....................",
                ".......aaaa.........",
                "......aaaaa.aaa.....",
                ".....bbbbbbbbbbb....",
                "....bbbbbbbbbbbbb...",
                "...cccWcccccccccc...",
                "..cccccWccccccccc...",
                "..ddddddWdddddddd...",
                "..dddddWdddddddddd..",
                "...eeeWeeeWWWWeeee..",
                "...eeeeeeeeeeeeeee..",
                "...ffffffffffffff...",
                "...fffffffffffff....",
                "....ggggggggggg.....",
                ".....ggg.ggggg......",
                ".........gggg.......",
                "....................",
                "....................",
            ],
            [ // 5: fall: 1 row up, glyphs trail 1 row high
                "....................",
                "....................",
                ".......aaaa.........",
                "......aaaaa.aaa.....",
                ".....bbbbbbbbbbb....",
                "....bbbbbbbbbbbbb...",
                "...cccWcccccccccc...",
                "..cccccWccccccccc...",
                "..ddddddWdddddddd...",
                "..dddddWdddddddddd..",
                "...eeeWeeeWWWWeeee..",
                "...eeeeeeeeeeeeeee..",
                "...ffffffffffffff...",
                "...fffffffffffff....",
                "....ggggggggggg.....",
                ".....ggg.ggggg......",
                ".........gggg.......",
                "....................",
            ],
        ],
        isTemplate: false,
        credit: "Codex logo © OpenAI — personal-use pixel adaptation. Not affiliated with or endorsed by OpenAI.",
        license: "OpenAI — personal use only",
        isBrandInspired: true,
        tags: ["personal-only", "brand-exact"]
    )
}
