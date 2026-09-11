import GoRunnerCore

// FACADE — `RunnerArtCatalog.all` is a contract used by GoRunnerApp. The first entry is the default runner.
//
// Each sprite lives in its own file under `Sprites/`. Third-party adaptations carry attribution in their file
// header and in THIRD_PARTY_NOTICES.md.

public enum RunnerArtCatalog {
    public static var all: [PixelSprite] {
        [clawd, codex, kodee, gopher, tux, kiro, grok]
    }
}
