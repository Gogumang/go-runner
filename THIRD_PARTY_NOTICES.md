# Third-party notices

go-runner is licensed under the Apache License 2.0, Copyright 2026 gogumang — see
`LICENSE` and `NOTICE`. The third-party code, character art and app icon listed below keep their own licenses and terms;
personal-use brand art is not covered by the project license.

go-runner is an independent app. It adapts code and techniques from the open-source projects below and is not
affiliated with or endorsed by their authors.

## Code and algorithms referenced

| Project | License | Used for |
|---|---|---|
| [runcat-dev/RunCatNeo](https://github.com/runcat-dev/RunCatNeo) | Apache-2.0 | Speed curve, CALayer keyframe animation technique, custom runner size rules. Adapted files carry Apache-2.0 header comments. |
| [Kyome22/SystemInfoKit](https://github.com/Kyome22/SystemInfoKit) | Apache-2.0 | CPU / memory / storage / battery / network metric formulas and display format |
| [runcat-dev/RunCat365](https://github.com/runcat-dev/RunCat365) | Apache-2.0 | FPS Max Limit option, speed source behavior |
| [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage) | MIT | 5-hour block algorithm for Claude Code logs (reimplemented) |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | MIT | Prior art for provider data sources (reimplemented) |

Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0 — MIT License: https://opensource.org/licenses/MIT

## Character art

| Runner | Source | License / attribution |
|---|---|---|
| Kodee | Kotlin mascot by JetBrains s.r.o. | CC BY 4.0 — "Kodee by JetBrains s.r.o. is licensed under CC BY 4.0." Pixel adaptation for go-runner. Kotlin is a trademark of JetBrains; not affiliated or endorsed. |
| Go gopher | Renée French | CC BY 4.0 — "The Go gopher was designed by Renée French." Pixel adaptation for go-runner. |
| Tux | Larry Ewing (lewing@isc.tamu.edu) and The GIMP | Use and modification permitted with acknowledgement |

| Clawd | Claude Code mascot, © Anthropic PBC | **Personal use only.** Fan pixel adaptation added at the user's request for a personal build. Clawd and Claude are trademarks of Anthropic; go-runner is not affiliated with or endorsed by Anthropic. Remove this runner (`RunnerArt/Sprites/Clawd.swift`, tagged `personal-only`) and the Clawd menu icon before any public distribution. |

| Codex | Codex logo, © OpenAI | **Personal use only.** Pixel adaptation of the logo from a reference image the user supplied; also used as the Codex finish-notification image. Not affiliated with or endorsed by OpenAI. Remove (`Sprites/Codex.swift`) before public distribution. |
| Kiro | Kiro, © Amazon Web Services | **Personal use only.** Fan pixel adaptation at the user's request. Not affiliated with or endorsed by AWS. Remove (`Sprites/Kiro.swift`) before public distribution. |
| Grok | Grok, © xAI | **Personal use only.** Fan pixel adaptation at the user's request. Not affiliated with or endorsed by xAI. Remove (`Sprites/Grok.swift`) before public distribution. |

Other brand-exact characters (e.g. 당근이) are not bundled.

## App icon

| Asset | Source | License / attribution |
|---|---|---|
| App icon (`Resources/AppIcon.icns`, from `Resources/AppIconSource.png`) | Interpark Tour app mark (runner figure), © NOL Universe | **Personal use only.** The user supplied the reference image; the generator (`Tests/RunnerArtTests/AppIconGeneratorTests.swift`) re-renders the figure on the macOS icon tile and sets "GO" in Avenir Next Demi Bold (a macOS system font) where the reference says "TOUR". Replace both files before public distribution unless approved by the brand team. |
