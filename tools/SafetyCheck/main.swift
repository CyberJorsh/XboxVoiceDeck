import Foundation

let result = OfflineSafetyCheck.run()
print(result.summary)
exit(result.passed ? 0 : 1)
