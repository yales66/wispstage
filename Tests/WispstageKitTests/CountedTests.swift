import Testing
@testable import WispstageKit

struct CountedTests {
    @Test(arguments: [
        (0, "step", "0 steps"),
        (1, "step", "1 step"),
        (2, "step", "2 steps"),
        (1, "torn frame", "1 torn frame"),
        (3, "torn frame", "3 torn frames"),
    ] as [(Int, String, String)])
    func pluralizesTheNounUnlessTheCountIsOne(_ n: Int, _ noun: String, _ want: String) {
        #expect(counted(n, noun) == want)
    }
}
