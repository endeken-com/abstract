import Darwin
import Testing
import TestProcess

/// The test process ignores SIGPIPE (see Tests/TestProcess), while what it
/// spawns gets the default back.
@Suite struct TestProcessTests {
    @Test func theTestProcessIgnoresSIGPIPE() {
        #expect(abstract_test_process_ignores_sigpipe() == 1)
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        #expect(handler == unsafeBitCast(SIG_IGN, to: Int.self))
    }

    @Test func aWriteToAClosedPipeFailsInsteadOfEndingTheRun() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])
        let byte: [UInt8] = [0x41]
        let written = write(fds[1], byte, 1)
        let error = errno
        close(fds[1])
        #expect(written == -1 && error == EPIPE)
    }
}
