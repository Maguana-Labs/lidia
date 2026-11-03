// Never shipped. This target exists so `xcodebuild -allowProvisioningUpdates` can register
// io.lidia.app with the iCloud and push capabilities and download a macOS provisioning
// profile for it: scripts/fetch-icloud-profile.sh copies that profile into LidIA.app
// (Contents/embedded.provisionprofile), which SwiftPM can't do on its own.
//
// `--check-icloud` checks a signing recipe without running LidIA (which would open the
// library): re-sign this stub the way run.sh signs LidIA, run it, and it reports whether
// macOS accepted the iCloud entitlements and what CloudKit says about the account.
// It reads the account status only; it never reads or writes records.
import CloudKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.contains("--check-icloud") else {
    print("LidIA provisioning stub")
    exit(0)
}

let containerID = "iCloud.io.lidia.app"
let done = DispatchSemaphore(value: 0)
CKContainer(identifier: containerID).accountStatus { status, error in
    let words: String
    switch status {
    case .available: words = "available"
    case .noAccount: words = "noAccount"
    case .restricted: words = "restricted"
    case .couldNotDetermine: words = "couldNotDetermine"
    case .temporarilyUnavailable: words = "temporarilyUnavailable"
    @unknown default: words = "unknown"
    }
    print("CloudKit container \(containerID): account \(words)\(error.map { " (error: \($0.localizedDescription))" } ?? "")")
    done.signal()
}
if done.wait(timeout: .now() + 30) == .timedOut {
    print("CloudKit didn't answer within 30 seconds")
    exit(2)
}
exit(0)
