import Testing

/// The suites that spawn dozens of git (or other) processes per test, run one
/// at a time. `.serialized` on a suite only orders its own tests, so these
/// suites used to overlap each other and saturate CI's 3-core runner until the
/// deadline-bound process tests missed their limits. Nested under this suite,
/// they run one after another while every other test still runs in parallel.
///
/// Each suite stays in its own file, as `extension GitHeavy { … }`. A new suite
/// built on `SubmoduleFixture`, or that otherwise spawns lots of processes per
/// test, belongs here too.
@Suite(.serialized)
enum GitHeavy {}
