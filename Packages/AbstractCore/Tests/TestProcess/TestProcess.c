// The test process ignores SIGPIPE from the moment it loads. On macOS a
// write to a pipe nobody reads sends SIGPIPE to the whole process, not the
// writing thread, so one stray write anywhere ended the entire test run
// ("exited with unexpected signal code 13") with no hint of which test.
// Ignored, that write fails with EPIPE and only its own test can fail.
// Children don't inherit it: Spawner resets every signal to its default.
#include <signal.h>
#include "TestProcess.h"

static int ignoring = 0;

__attribute__((constructor)) static void abstract_test_process_ignore_sigpipe(void) {
    if (signal(SIGPIPE, SIG_IGN) != SIG_ERR) ignoring = 1;
}

int abstract_test_process_ignores_sigpipe(void) { return ignoring; }
