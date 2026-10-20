import Foundation

runCatalogTests()
runAgentTests()
runProbeTests()
runGlyphTests()
runMarkTests()
runSafetyTests()
runKeeperTests()
runCursorStateTests()
runLoopTests()
runPresentationTests()
runPanelSessionTests()
runChannelTests()
runAppTests()

print("\(checkCount) checks, \(failureCount) failures")
exit(failureCount == 0 ? 0 : 1)
