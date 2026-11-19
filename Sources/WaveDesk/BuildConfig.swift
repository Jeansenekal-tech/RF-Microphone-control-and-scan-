// Values for distributed builds. build_app.sh overwrites this file during a release build
// (from environment variables / GitHub secrets) and restores it afterwards.
// With an empty keygenAccountID the app runs as an unlicensed developer build.
enum BuildConfig {
    static let keygenAccountID = ""
    static let keygenPublicKey = ""
    static let trialURL = ""
    static let purchaseURL = ""
    static let releasesRepo = "Jeansenekal-tech/rf-microphone-control-and-scan-"
}
