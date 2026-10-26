#ifndef TEST_PROCESS_H
#define TEST_PROCESS_H

/// Whether the test process ignores SIGPIPE; calling it links the
/// constructor that sets that up into the test bundle.
int abstract_test_process_ignores_sigpipe(void);

#endif
