import Foundation
import ConnectIQ
import ComposeApp

/// The Garmin watch link on iPhone ([[garmin-watch-app]]).
///
/// Garmin's iOS SDK does not let an app scan for a watch: the shooter chooses one in Garmin Connect, which
/// hands the choice back by opening `coriolisciq://...` (Info.plist), and `iOSApp` passes that URL to
/// `handle(_:)`. The chosen watch is kept, so it is chosen once. Messages then go phone -> Garmin's SDK ->
/// watch over Bluetooth, which is why the app carries a Bluetooth usage string.
///
/// It reports and carries; it decides nothing. The payload comes ready-made from Kotlin, exactly as on Android.
final class GarminLink: NSObject, GarminBridge, IQDeviceEventDelegate {
    static let urlScheme = "coriolisciq"
    private static let savedKey = "coriolis.garmin.devices"

    private var reply: GarminStatusReply?
    private var appUuid: UUID?
    private var device: IQDevice?
    private var app: IQApp?
    private var initialised = false
    /// The last state reported - Refresh re-opens the watch chooser unless the link is actually working.
    private var lastState = ""

    private func report(_ state: String, _ watch: String? = nil, _ detail: String? = nil) {
        lastState = state
        DispatchQueue.main.async { self.reply?.status(state: state, watch: watch, detail: detail) }
    }

    /// Garmin Connect's watch chooser. Called by its Objective-C name: how Swift renames
    /// showConnectIQDeviceSelection is not certain from here, and a selector cannot be misspelt by Swift.
    private func chooseWatch() {
        _ = ConnectIQ.sharedInstance().perform(NSSelectorFromString("showConnectIQDeviceSelection"))
    }

    // MARK: GarminBridge

    func start(appUuid: String, reply: GarminStatusReply) {
        self.reply = reply
        self.appUuid = UUID(uuidString: appUuid)
        if !initialised {
            ConnectIQ.sharedInstance().initialize(withUrlScheme: GarminLink.urlScheme, uiOverrideDelegate: nil)
            initialised = true
        }
        if let saved = loadDevices().first {
            use(saved)
        } else {
            report("NO_WATCH", nil, "Tap Refresh to choose your watch in Garmin Connect")
        }
    }

    /// Working: check it again. Anything else - no watch yet, the wrong one, a replaced one - choose again in
    /// Garmin Connect, whose answer comes back through handle(_:).
    func refresh() {
        if device != nil && (lastState == "READY" || lastState == "SENDING") {
            checkApp()
        } else {
            chooseWatch()
        }
    }

    func send(payload: [String : Any]) {
        guard let a = app, let d = device else { return }
        report("SENDING", d.friendlyName)
        ConnectIQ.sharedInstance().sendMessage(payload, to: a, progress: { _, _ in }, completion: { [weak self] result in
            guard let self = self else { return }
            if result == .success {
                self.report("READY", d.friendlyName)
            } else {
                self.report("ERROR", d.friendlyName, NSStringFromSendMessageResult(result))
            }
        })
    }

    func stop() {
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        device = nil
        app = nil
        report("UNSUPPORTED")
    }

    // MARK: the answer from Garmin Connect

    /// True when the URL was Garmin Connect's reply (and has been dealt with).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == GarminLink.urlScheme else { return false }
        let devices = (ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice]) ?? []
        // A cancelled or empty answer keeps the watch chosen before.
        guard let d = devices.first else {
            report("NO_WATCH", device?.friendlyName, "No watch was shared from Garmin Connect")
            return true
        }
        saveDevices(devices)
        use(d)
        return true
    }

    // MARK: the watch

    private func use(_ d: IQDevice) {
        if let old = device { ConnectIQ.sharedInstance().unregister(forDeviceEvents: old, delegate: self) }
        device = d
        ConnectIQ.sharedInstance().register(forDeviceEvents: d, delegate: self)
        if let id = appUuid { app = IQApp(uuid: id, store: id, device: d) }
        // Asked only once the watch can answer; otherwise deviceCharacteristicsDiscovered asks.
        if ConnectIQ.sharedInstance().getDeviceStatus(d) == .connected {
            checkApp()
        } else {
            report("NO_WATCH", d.friendlyName, "Waiting for the watch")
        }
    }

    /// Is OUR app on the watch? Garmin answers asynchronously.
    private func checkApp() {
        guard let a = app, let d = device else { return }
        ConnectIQ.sharedInstance().getAppStatus(a, completion: { [weak self] status in
            guard let self = self else { return }
            // No answer at all is not "not installed": the watch did not reply.
            guard let status = status else {
                self.report("NO_WATCH", d.friendlyName, "The watch did not answer")
                return
            }
            if status.isInstalled {
                self.report("READY", d.friendlyName)
            } else {
                self.report("NOT_INSTALLED", d.friendlyName, "Coriolis is not on the watch yet")
            }
        })
    }

    // MARK: IQDeviceEventDelegate

    func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let name = device?.friendlyName
        switch status {
        case .connected:
            break   // not yet able to talk: deviceCharacteristicsDiscovered says when it is
        case .invalidDevice:
            report("NO_WATCH", name, "Tap Refresh to choose your watch")
        case .bluetoothNotReady:
            report("ERROR", name, "Bluetooth is off")
        case .notConnected, .notFound:
            report("NO_WATCH", name, "The watch is not connected")
        default:
            break
        }
    }

    /// The watch is connected AND ready to talk - Garmin's own signal that messages will now get through.
    func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        checkApp()
    }

    // MARK: remembering the chosen watch

    private func saveDevices(_ devices: [IQDevice]) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: devices, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: GarminLink.savedKey)
        }
    }

    private func loadDevices() -> [IQDevice] {
        guard let data = UserDefaults.standard.data(forKey: GarminLink.savedKey) else { return [] }
        return (try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: IQDevice.self, from: data)) ?? []
    }
}
