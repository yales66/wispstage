/// "1 step", "2 steps": English count plus noun for log and summary lines, so the framework's own output passes its plural check.
func counted(_ n: Int, _ noun: String) -> String {
    "\(n) \(noun)\(n == 1 ? "" : "s")"
}
