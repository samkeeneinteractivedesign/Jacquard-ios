// Switches for the parts of the app a fork is likely to want to drop.
//
// Not part of the upstream design: this repo is meant as a base for new instruments, and
// these are the pieces that belong to Jacquard the product rather than to the sequencer
// and synth underneath it. Turning one off here removes it outright; nothing else has
// to change.

enum Features {
    // The three welcome pages on launch, and the grey laid over the screen behind them.
    // Also skipped for one run with the launch argument `-skipOnboarding`, and for good
    // once a player ticks "Don't show this again".
    static let onboarding = true
}
