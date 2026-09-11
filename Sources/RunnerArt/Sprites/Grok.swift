// Grok — fan pixel adaptation of the Grok (xAI) character look, for PERSONAL USE ONLY.
// Grok © xAI. Not affiliated with or endorsed by xAI. Do not redistribute or export.
//
// Reference (2026-09-11): the image the user supplied as "the Grok image" — a 240×240 Google image thumbnail
// (gstatic), kept locally at scratchpad/refs/grok-ref.jpeg; it replaces the earlier design built from the Wikimedia
// Grok logo (https://commons.wikimedia.org/wiki/File:Grok-feb-2025-logo.svg, ring crossed by a slash).
// The reference shows a glossy white/light-gray ball on black with two black pill-shaped eyes, upper center, each a tall
// oval leaning top-left → bottom-right, the right eye set a little higher (the ball is turned slightly right). Read
// from the image downsampled to 24×24 and 48×48: the body is light gray, a white specular patch sits around and right
// of the eyes, and a mid-gray crescent runs along the lower-left edge.
// (xAI's official Grok companions are Ani, Rudi and Valentine — https://grokipedia.com/page/Grok_companions — none is
// this ball; the user asked for this look.)
// Design: 14-cell ball with a 1-cell #8C8C8C outline (the white ball otherwise vanishes on a #ECECEC bar), shaded in
// three tones (#D9D9D9 body, an #A6A6A6 crescent on the lower left as in the reference, and a 2×2 #FFFFFF gloss above
// the eyes — kept off the pills, because white touching them reads as eye whites at this size), two black pill eyes
// (2×5) that step one column right partway down. No legs (the user asked for them to be removed).
// 20×18 canvas. 6-frame hop in place: contact → rise → rise → apex → fall → fall.
//   contact: squashed to 16×13 (centred on the round ball's axis, squat 2×4 eyes), bottom edge on row 17;
//   rise:    round 14×14, 1 then 2 rows up, eyes trailing one row low;
//   apex:    3 rows up, eyes centred;
//   fall:    2 then 1 row up, eyes trailing one row high, back into the squash.

import GoRunnerCore

extension RunnerArtCatalog {
    /// Grok (personal use only): glossy white ball with two slanted black pill eyes, hopping in place.
    /// Squashes on contact, stays round in the air; the eyes trail the bob by one row.
    /// 6 frames, 20×18 cells.
    static let grok = PixelSprite(
        id: "grok",
        names: ["ko": "그록", "en": "Grok"],
        palette: [
            "W": 0xFFFFFFFF, // gloss — 2×2 above the eyes
            "l": 0xD9D9D9FF, // ball — light gray
            "m": 0xA6A6A6FF, // shade — mid gray (lower-left crescent)
            "o": 0x8C8C8CFF, // 1-cell outline so the white ball holds on light menu bars
            "e": 0x0A0A0AFF, // pill eyes
        ],
        frames: [
            [ // 0: contact: squashed on the ground (16×13), squat 4-row eyes
                "....................",
                "....................",
                "....................",
                "....................",
                "....................",
                ".......oooooo.......",
                ".....oolWWllloo.....",
                "....olllWWlllllo....",
                "...ollllllleelllo...",
                "..olllleelleellllo..",
                "..olllleellleelllo..",
                "..omlllleelleelllo..",
                "..omlllleelllllllo..",
                "..ommllllllllllllo..",
                "...ommllllllllllo...",
                "....ommmlllllllo....",
                ".....oommmmmmoo.....",
                ".......oooooo.......",
            ],
            [ // 1: rise: round again, 1 row up, eyes trail 1 row low
                "....................",
                "....................",
                "....................",
                ".......oooooo.......",
                "......olWWlllo......",
                ".....ollWWllllo.....",
                "....ollllllllllo....",
                "...ollllllleelllo...",
                "...ollleelleelllo...",
                "...ollleellleello...",
                "...omllleelleello...",
                "...omllleelleello...",
                "...ommlleellllllo...",
                "....ommllllllllo....",
                ".....ommmlllllo.....",
                "......ommmmmmo......",
                ".......oooooo.......",
                "....................",
            ],
            [ // 2: rise: 2 rows up, eyes trail 1 row low
                "....................",
                "....................",
                ".......oooooo.......",
                "......olWWlllo......",
                ".....ollWWllllo.....",
                "....ollllllllllo....",
                "...ollllllleelllo...",
                "...ollleelleelllo...",
                "...ollleellleello...",
                "...omllleelleello...",
                "...omllleelleello...",
                "...ommlleellllllo...",
                "....ommllllllllo....",
                ".....ommmlllllo.....",
                "......ommmmmmo......",
                ".......oooooo.......",
                "....................",
                "....................",
            ],
            [ // 3: apex: 3 rows up, eyes centred
                "....................",
                ".......oooooo.......",
                "......olWWlllo......",
                ".....ollWWllllo.....",
                "....olllllleello....",
                "...ollleelleelllo...",
                "...ollleellleello...",
                "...olllleelleello...",
                "...omllleelleello...",
                "...omllleellllllo...",
                "...ommllllllllllo...",
                "....ommllllllllo....",
                ".....ommmlllllo.....",
                "......ommmmmmo......",
                ".......oooooo.......",
                "....................",
                "....................",
                "....................",
            ],
            [ // 4: fall: 2 rows up, eyes trail 1 row high
                "....................",
                "....................",
                ".......oooooo.......",
                "......olWWWllo......",
                ".....olllWleelo.....",
                "....olleelleello....",
                "...ollleellleello...",
                "...olllleelleello...",
                "...olllleelleello...",
                "...omllleellllllo...",
                "...omlllllllllllo...",
                "...ommllllllllllo...",
                "....ommllllllllo....",
                ".....ommmlllllo.....",
                "......ommmmmmo......",
                ".......oooooo.......",
                "....................",
                "....................",
            ],
            [ // 5: fall: 1 row up, eyes trail 1 row high
                "....................",
                "....................",
                "....................",
                ".......oooooo.......",
                "......olWWWllo......",
                ".....olllWleelo.....",
                "....olleelleello....",
                "...ollleellleello...",
                "...olllleelleello...",
                "...olllleelleello...",
                "...omllleellllllo...",
                "...omlllllllllllo...",
                "...ommllllllllllo...",
                "....ommllllllllo....",
                ".....ommmlllllo.....",
                "......ommmmmmo......",
                ".......oooooo.......",
                "....................",
            ],
        ],
        isTemplate: false,
        credit: "Grok © xAI — fan pixel adaptation for personal use. Not affiliated with or endorsed by xAI.",
        license: "xAI — personal use only",
        isBrandInspired: true,
        tags: ["personal-only", "brand-exact"]
    )
}
