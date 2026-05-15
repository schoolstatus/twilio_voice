import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit
import UserNotifications

public class SwiftTwilioVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate {
    
    // MARK: - Singleton
    private static var sharedInstance: SwiftTwilioVoicePlugin?
    
    // MARK: - Properties
    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?
    
    let kRegistrationTTLInDays = 365
    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String:String]!
    
    var accessToken: String?
    var identity = "alice"
    var callTo: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get { UserDefaults.standard.data(forKey: kCachedDeviceToken) }
        set { UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken) }
    }
    var callArgs: Dictionary<String, AnyObject> = [String: AnyObject]()
    
    // Push completion callback - CRITICAL for iOS 26 compliance
    // Must be called AFTER reportNewIncomingCall, not before
    var pendingPushCompletion: (() -> Void)?
    var pushCompletionTimer: DispatchWorkItem?
    
    var callInvite: CallInvite?
    var call: Call?
    var callKitCompletionCallback: ((Bool) -> Swift.Void?)?
    var audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callOutgoing: Bool = false
    
    static var appName: String {
        get {
            return (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }
    
    // MARK: - Initialization
    public override init() {
        let configuration = CXProviderConfiguration(localizedName: SwiftTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        if let callKitIcon = UIImage(named: "callkit_icon") {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }
        
        clients = UserDefaults.standard.object(forKey: kClientList) as? [String:String] ?? [:]
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        super.init()
        
        NSLog("[TwilioVoice] Plugin init()")
        
        callKitProvider.setDelegate(self, queue: nil)
        
        // Set up NotificationCenter observers for AppDelegate VoIP events
        // On iOS 26+, PKPushRegistry MUST be initialized in AppDelegate before Flutter
        setupAppDelegateObservers()
        
        // Check if AppDelegate already has a VoIP token
        checkForExistingVoIPToken()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        callKitProvider.invalidate()
    }
    
    // MARK: - AppDelegate Communication
    
    private func setupAppDelegateObservers() {
        NSLog("[TwilioVoice] Setting up AppDelegate observers")
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDelegateVoIPToken(_:)),
            name: NSNotification.Name("AppDelegateVoIPTokenUpdated"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDelegateVoIPPush(_:)),
            name: NSNotification.Name("AppDelegateVoIPPushReceived"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDelegateVoIPTokenInvalidated(_:)),
            name: NSNotification.Name("AppDelegateVoIPTokenInvalidated"),
            object: nil
        )
    }
    
    private func checkForExistingVoIPToken() {
        if let appDelegate = UIApplication.shared.delegate,
           appDelegate.responds(to: Selector(("getVoIPToken"))),
           let token = appDelegate.perform(Selector(("getVoIPToken")))?.takeUnretainedValue() as? Data {
            let hex = token.map { String(format: "%02x", $0) }.joined()
            NSLog("[TwilioVoice] Found existing VoIP token: \(hex)")
            handleVoIPTokenUpdate(token: token)
        }
    }
    
    @objc private func handleAppDelegateVoIPToken(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let token = userInfo["token"] as? Data else {
            NSLog("[TwilioVoice] ERROR: Invalid token notification")
            return
        }
        
        let hex = token.map { String(format: "%02x", $0) }.joined()
        NSLog("[TwilioVoice] VoIP token from AppDelegate: \(hex)")
        handleVoIPTokenUpdate(token: token)
    }
    
    @objc private func handleAppDelegateVoIPPush(_ notification: Notification) {
        NSLog("[TwilioVoice] *** VoIP PUSH RECEIVED ***")
        self.sendPhoneCallEvents(description: "LOG|*** VoIP PUSH RECEIVED ***", isError: false)
        
        guard let userInfo = notification.userInfo,
              let payload = userInfo["payload"] as? [AnyHashable: Any] else {
            NSLog("[TwilioVoice] ERROR: Invalid push payload")
            return
        }
        
        let mustReport = userInfo["mustReport"] as? Bool ?? true
        let completion = userInfo["completion"] as? (() -> Void)
        
        NSLog("[TwilioVoice] Push mustReport=\(mustReport), payload keys: \(payload.keys)")
        self.sendPhoneCallEvents(description: "LOG|Push mustReport=\(mustReport)", isError: false)
        
        // Store completion - will be called AFTER reportNewIncomingCall (F1 fix)
        self.pendingPushCompletion = completion
        
        // Safety timeout: complete after 5s if Twilio SDK doesn't callback
        pushCompletionTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            NSLog("[TwilioVoice] Push completion timeout - forcing completion")
            self?.completePendingPush()
        }
        pushCompletionTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timer)
        
        // Handle with Twilio SDK
        TwilioVoiceSDK.handleNotification(payload, delegate: self, delegateQueue: nil)
    }
    
    @objc private func handleAppDelegateVoIPTokenInvalidated(_ notification: Notification) {
        NSLog("[TwilioVoice] VoIP token invalidated")
        self.sendPhoneCallEvents(description: "LOG|VoIP token invalidated", isError: false)
        self.unregister()
    }
    
    private func handleVoIPTokenUpdate(token: Data) {
        self.sendPhoneCallEvents(description: "LOG|VoIP token received", isError: false)
        
        let regRequired = registrationRequired()
        let tokenChanged = deviceToken != token
        
        guard regRequired || tokenChanged else {
            self.sendPhoneCallEvents(description: "LOG|Registration not required", isError: false)
            return
        }
        
        if let accessToken = self.accessToken {
            self.sendPhoneCallEvents(description: "LOG|Registering with Twilio", isError: false)
            TwilioVoiceSDK.register(accessToken: accessToken, deviceToken: token) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|Registration error: \(error.localizedDescription)", isError: false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push", isError: false)
                }
            }
        } else {
            self.sendPhoneCallEvents(description: "LOG|No accessToken yet, caching token", isError: false)
        }
        
        self.deviceToken = token
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
    }
    
    private func completePendingPush() {
        pushCompletionTimer?.cancel()
        pushCompletionTimer = nil
        
        if let completion = pendingPushCompletion {
            NSLog("[TwilioVoice] Completing push")
            pendingPushCompletion = nil
            completion()
        }
    }
    
    // MARK: - Plugin Registration
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        NSLog("[TwilioVoice] register(with:) called")
        
        let instance: SwiftTwilioVoicePlugin
        if let existing = sharedInstance {
            instance = existing
            NSLog("[TwilioVoice] Reusing existing instance")
        } else {
            instance = SwiftTwilioVoicePlugin()
            sharedInstance = instance
            NSLog("[TwilioVoice] Created new instance")
        }
        
        let methodChannel = FlutterMethodChannel(name: "twilio_voice/messages", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        registrar.addApplicationDelegate(instance)
    }
    
    // MARK: - Flutter Method Channel Handler
    
    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        _result = result
        
        let arguments: Dictionary<String, AnyObject> = flutterCall.arguments as? Dictionary<String, AnyObject> ?? [:]
        
        if flutterCall.method == "loadDeviceToken" {
            if let deviceToken = deviceToken {
                self.sendPhoneCallEvents(description: "DEVICETOKEN|\(deviceToken.hexString)", isError: false)
                result(true)
                return
            }
            result(false)
            return
        }
        
        if flutterCall.method == "tokens" {
            guard let token = arguments["accessToken"] as? String else {
                result(false)
                return
            }
            self.accessToken = token
            
            if let deviceToken = deviceToken {
                self.sendPhoneCallEvents(description: "LOG|Registering with Twilio", isError: false)
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|Registration error: \(error.localizedDescription)", isError: false)
                    } else {
                        self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push", isError: false)
                    }
                }
            } else {
                self.sendPhoneCallEvents(description: "LOG|No deviceToken yet", isError: false)
            }
            result(true)
            return
        }
        
        if flutterCall.method == "makeCall" {
            guard let callTo = arguments["To"] as? String else { result(false); return }
            guard let callFrom = arguments["From"] as? String else { result(false); return }
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String {
                self.accessToken = accessToken
            }
            self.callTo = callTo
            self.identity = callFrom
            makeCall(to: callTo)
            result(true)
            return
        }
        
        if flutterCall.method == "toggleMute" {
            guard let muted = arguments["muted"] as? Bool else { result(false); return }
            if let call = self.call {
                call.isMuted = muted
                eventSink?(muted ? "Mute" : "Unmute")
                result(true)
            } else {
                result(FlutterError(code: "MUTE_ERROR", message: "No call to be muted", details: nil))
            }
            return
        }
        
        if flutterCall.method == "toggleSpeaker" {
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else { result(false); return }
            toggleAudioRoute(toSpeaker: speakerIsOn)
            eventSink?(speakerIsOn ? "Speaker On" : "Speaker Off")
            result(true)
            return
        }
        
        if flutterCall.method == "call-sid" {
            result(self.call?.sid)
            return
        }
        
        if flutterCall.method == "isOnCall" {
            result(self.call != nil)
            return
        }
        
        if flutterCall.method == "sendDigits" {
            guard let digits = arguments["digits"] as? String else { result(false); return }
            self.call?.sendDigits(digits)
            result(true)
            return
        }
        
        if flutterCall.method == "holdCall" {
            if let call = self.call {
                let hold = call.isOnHold
                call.isOnHold = !hold
                eventSink?(!hold ? "Hold" : "Unhold")
            }
            result(true)
            return
        }
        
        if flutterCall.method == "answer" {
            result(true)
            return
        }
        
        if flutterCall.method == "unregister" {
            guard let deviceToken = deviceToken else {
                result(false)
                return
            }
            if let token = arguments["accessToken"] as? String {
                self.unregisterTokens(token: token, deviceToken: deviceToken)
            } else if let token = accessToken {
                self.unregisterTokens(token: token, deviceToken: deviceToken)
            }
            result(true)
            return
        }
        
        if flutterCall.method == "hangUp" {
            if let call = self.call, call.state == .connected {
                self.sendPhoneCallEvents(description: "LOG|hangUp invoked", isError: false)
                self.userInitiatedDisconnect = true
                performEndCallAction(uuid: call.uuid!)
            }
            result(true)
            return
        }
        
        if flutterCall.method == "registerClient" {
            guard let clientId = arguments["id"] as? String,
                  let clientName = arguments["name"] as? String else { result(false); return }
            if clients[clientId] == nil || clients[clientId] != clientName {
                clients[clientId] = clientName
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
            result(true)
            return
        }
        
        if flutterCall.method == "unregisterClient" {
            guard let clientId = arguments["id"] as? String else { result(false); return }
            clients.removeValue(forKey: clientId)
            UserDefaults.standard.set(clients, forKey: kClientList)
            result(true)
            return
        }
        
        if flutterCall.method == "defaultCaller" {
            guard let caller = arguments["defaultCaller"] as? String else { result(false); return }
            defaultCaller = caller
            if clients["defaultCaller"] == nil || clients["defaultCaller"] != defaultCaller {
                clients["defaultCaller"] = defaultCaller
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
            result(true)
            return
        }
        
        if flutterCall.method == "hasMicPermission" {
            let permission = AVAudioSession.sharedInstance().recordPermission
            result(permission == .granted)
            return
        }
        
        if flutterCall.method == "requestMicPermission" {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                result(true)
            case .denied:
                result(false)
            case .undetermined:
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    result(granted)
                }
            @unknown default:
                result(false)
            }
            return
        }
        
        if flutterCall.method == "show-notifications" {
            guard let show = arguments["show"] as? Bool else { result(false); return }
            let prefsShow = UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true
            if show != prefsShow {
                UserDefaults.standard.setValue(show, forKey: "show-notifications")
            }
            result(true)
            return
        }
        
        result(true)
    }
    
    // MARK: - Call Management
    
    func makeCall(to: String) {
        if let call = self.call, call.state == .connected {
            self.userInitiatedDisconnect = true
            performEndCallAction(uuid: call.uuid!)
        } else {
            let uuid = UUID()
            
            self.checkRecordPermission { permissionGranted in
                if !permissionGranted {
                    let alertController = UIAlertController(
                        title: String(format: NSLocalizedString("mic_permission_title", comment: ""), SwiftTwilioVoicePlugin.appName),
                        message: NSLocalizedString("mic_permission_subtitle", comment: ""),
                        preferredStyle: .alert
                    )
                    
                    alertController.addAction(UIAlertAction(
                        title: NSLocalizedString("btn_continue_no_mic", comment: ""),
                        style: .default
                    ) { _ in
                        self.performStartCallAction(uuid: uuid, handle: to)
                    })
                    
                    alertController.addAction(UIAlertAction(
                        title: NSLocalizedString("btn_settings", comment: ""),
                        style: .default
                    ) { _ in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    })
                    
                    alertController.addAction(UIAlertAction(
                        title: NSLocalizedString("btn_cancel", comment: ""),
                        style: .cancel
                    ))
                    
                    if let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() {
                        currentViewController.present(alertController, animated: true)
                    }
                } else {
                    self.performStartCallAction(uuid: uuid, handle: to)
                }
            }
        }
    }
    
    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }
    
    // MARK: - PKPushRegistryDelegate (Legacy - now handled via AppDelegate)
    
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        // This is called if PKPushRegistry is initialized in the plugin (legacy path)
        // For iOS 26, AppDelegate should handle this
        NSLog("[TwilioVoice] pushRegistry didUpdate credentials (plugin)")
        guard type == .voIP else { return }
        handleVoIPTokenUpdate(token: credentials.token)
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        NSLog("[TwilioVoice] pushRegistry didInvalidate (plugin)")
        guard type == .voIP else { return }
        self.unregister()
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        // Deprecated - iOS 11+
        NSLog("[TwilioVoice] pushRegistry didReceiveIncomingPush (deprecated)")
        guard type == .voIP else { return }
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // Legacy iOS 11+ handler - for non-iOS 26 builds
        NSLog("[TwilioVoice] pushRegistry didReceiveIncomingPush with completion (plugin)")
        guard type == .voIP else { completion(); return }
        
        // Store completion - will be called AFTER reportNewIncomingCall
        self.pendingPushCompletion = completion
        
        // Safety timeout
        pushCompletionTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.completePendingPush()
        }
        pushCompletionTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timer)
        
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
    }
    
    // MARK: - Registration
    
    func registrationRequired() -> Bool {
        guard let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate) as? Date else {
            return true
        }
        
        var components = DateComponents()
        components.setValue(kRegistrationTTLInDays / 2, for: .day)
        let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated)!
        
        return Date() >= expirationDate
    }
    
    func unregister() {
        guard let deviceToken = deviceToken, let token = accessToken else { return }
        self.unregisterTokens(token: token, deviceToken: deviceToken)
    }
    
    func unregisterTokens(token: String, deviceToken: Data) {
        TwilioVoiceSDK.unregister(accessToken: token, deviceToken: deviceToken) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|Unregister error: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Successfully unregistered", isError: false)
            }
        }
        UserDefaults.standard.removeObject(forKey: kCachedBindingDate)
    }
    
    // MARK: - TVONotificationDelegate
    
    public func callInviteReceived(callInvite: CallInvite) {
        NSLog("[TwilioVoice] callInviteReceived")
        self.sendPhoneCallEvents(description: "LOG|callInviteReceived", isError: false)
        
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        var from: String = callInvite.from ?? defaultCaller
        from = from.replacingOccurrences(of: "client:", with: "")
        
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to)|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        
        self.callInvite = callInvite
        
        // Report to CallKit, then complete the push (F1 fix)
        reportIncomingCall(from: from, uuid: callInvite.uuid) { [weak self] error in
            if let error = error {
                NSLog("[TwilioVoice] reportIncomingCall failed: \(error.localizedDescription)")
                // F7 fix: Clean up on failure
                self?.callInvite?.reject()
                self?.callInvite = nil
            }
            // Complete push AFTER reporting (F1 fix - critical for iOS 26)
            self?.completePendingPush()
        }
    }
    
    func formatCustomParams(params: [String: Any]?) -> String {
        guard let customParameters = params else { return "" }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                return "|\(jsonStr)"
            }
        } catch {
            print("unable to send custom parameters")
        }
        return ""
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        NSLog("[TwilioVoice] cancelledCallInviteReceived")
        self.sendPhoneCallEvents(description: "Missed Call", isError: false)
        self.sendPhoneCallEvents(description: "LOG|cancelledCallInviteReceived", isError: false)
        
        self.showMissedCallNotification(from: cancelledCallInvite.from, to: cancelledCallInvite.to)
        
        if let ci = self.callInvite {
            // Report end to CallKit
            callKitProvider.reportCall(with: ci.uuid, endedAt: Date(), reason: .answeredElsewhere)
            self.callInvite = nil
        }
        
        // Complete any pending push
        completePendingPush()
    }
    
    func showMissedCallNotification(from: String?, to: String?) {
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else { return }
        
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            
            let content = UNMutableNotificationContent()
            var userName: String?
            
            if var from = from {
                from = from.replacingOccurrences(of: "client:", with: "")
                content.userInfo = ["type": "twilio-missed-call", "From": from]
                if let to = to {
                    content.userInfo["To"] = to
                }
                userName = self.clients[from]
            }
            
            let title = userName ?? self.clients["defaultCaller"] ?? self.defaultCaller
            content.title = String(format: NSLocalizedString("notification_missed_call", comment: ""), title)
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            notificationCenter.add(request) { error in
                if let error = error {
                    print("Notification Error: ", error)
                }
            }
        }
    }
    
    // MARK: - TVOCallDelegate
    
    public func callDidStartRinging(call: Call) {
        let direction = self.callOutgoing ? "Outgoing" : "Incoming"
        let from = call.from ?? self.identity
        let to = call.to ?? self.callTo
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(to)|\(direction)", isError: false)
    }
    
    public func callDidConnect(call: Call) {
        let direction = self.callOutgoing ? "Outgoing" : "Incoming"
        let from = call.from ?? self.identity
        let to = call.to ?? self.callTo
        self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)
        
        if let callback = callKitCompletionCallback {
            callback(true)
        }
        
        toggleAudioRoute(toSpeaker: false)
    }
    
    public func call(call: Call, isReconnectingWithError error: Error) {
        self.sendPhoneCallEvents(description: "LOG|call:isReconnectingWithError", isError: false)
    }
    
    public func callDidReconnect(call: Call) {
        self.sendPhoneCallEvents(description: "LOG|callDidReconnect", isError: false)
    }
    
    public func callDidFailToConnect(call: Call, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|Call failed to connect: \(error.localizedDescription)", isError: false)
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        
        if error.localizedDescription.contains("Access Token expired") {
            self.sendPhoneCallEvents(description: "DEVICETOKEN", isError: false)
        }
        
        callKitCompletionCallback?(false)
        
        if let uuid = call.uuid {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        callDisconnected()
    }
    
    public func callDidDisconnect(call: Call, error: Error?) {
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        if let error = error {
            self.sendPhoneCallEvents(description: "Call Failed: \(error.localizedDescription)", isError: true)
        }
        
        if !self.userInitiatedDisconnect {
            var reason = CXCallEndedReason.remoteEnded
            if error != nil {
                reason = .failed
            }
            if let uuid = call.uuid {
                self.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            }
        }
        
        callDisconnected()
    }
    
    func callDisconnected() {
        self.sendPhoneCallEvents(description: "LOG|Call Disconnected", isError: false)
        self.call = nil
        self.callInvite = nil
        self.callOutgoing = false
        self.userInitiatedDisconnect = false
    }
    
    // MARK: - AVAudioSession
    
    func toggleAudioRoute(toSpeaker: Bool) {
        audioDevice.block = {
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            do {
                if toSpeaker {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                } else {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                }
            } catch {
                self.sendPhoneCallEvents(description: "LOG|\(error.localizedDescription)", isError: false)
            }
        }
        audioDevice.block()
    }
    
    // MARK: - CXProviderDelegate
    
    public func providerDidReset(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidReset", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func providerDidBegin(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidBegin", isError: false)
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didActivateAudioSession", isError: false)
        audioDevice.isEnabled = true
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didDeactivateAudioSession", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:timedOutPerformingAction", isError: false)
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performStartCallAction", isError: false)
        
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        
        self.performVoiceCall(uuid: action.callUUID, client: "") { success in
            if success {
                self.sendPhoneCallEvents(description: "LOG|performVoiceCall successful", isError: false)
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            } else {
                self.sendPhoneCallEvents(description: "LOG|performVoiceCall failed", isError: false)
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performAnswerCallAction", isError: false)
        
        // F2 fix: Only fulfill after successful answer, fail otherwise
        self.performAnswerVoiceCall(uuid: action.callUUID) { success in
            if success {
                self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall successful", isError: false)
                action.fulfill()
            } else {
                self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall failed", isError: false)
                action.fail()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction", isError: false)
        
        if let callInvite = self.callInvite {
            self.sendPhoneCallEvents(description: "LOG|Rejecting call", isError: false)
            callInvite.reject()
            self.callInvite = nil
        } else if let call = self.call {
            self.sendPhoneCallEvents(description: "LOG|Disconnecting call", isError: false)
            call.disconnect()
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction", isError: false)
        if let call = self.call {
            call.isOnHold = action.isOnHold
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetMutedAction", isError: false)
        if let call = self.call {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    // MARK: - CallKit Actions
    
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|StartCallAction failed: \(error.localizedDescription)", isError: false)
                return
            }
            
            self.sendPhoneCallEvents(description: "LOG|StartCallAction successful", isError: false)
            
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.localizedCallerName = self.clients[handle] ?? self.clients["defaultCaller"] ?? self.defaultCaller
            callUpdate.supportsDTMF = false
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            
            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
        }
    }
    
    func reportIncomingCall(from: String, uuid: UUID, completion: ((Error?) -> Void)? = nil) {
        let callHandle = CXHandle(type: .generic, value: from)
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.localizedCallerName = clients[from] ?? self.clients["defaultCaller"] ?? defaultCaller
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|Failed to report incoming call: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Incoming call reported successfully", isError: false)
            }
            completion?(error)
        }
    }
    
    func performEndCallAction(uuid: UUID) {
        self.sendPhoneCallEvents(description: "LOG|performEndCallAction invoked", isError: false)
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        callKitCallController.request(transaction) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription)", isError: true)
            } else {
                self.sendPhoneCallEvents(description: "Call Ended", isError: false)
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
        guard let token = accessToken else {
            completionHandler(false)
            return
        }
        
        let connectOptions = ConnectOptions(accessToken: token) { builder in
            for (key, value) in self.callArgs {
                if key != "From" {
                    builder.params[key] = "\(value)"
                }
            }
            builder.uuid = uuid
        }
        let theCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        self.call = theCall
        self.callKitCompletionCallback = completionHandler
    }
    
    func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
        guard let ci = self.callInvite else {
            self.sendPhoneCallEvents(description: "LOG|No CallInvite matches the UUID", isError: false)
            // F2 fix: Report failure and clean up
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            completionHandler(false)
            return
        }
        
        let acceptOptions = AcceptOptions(callInvite: ci) { builder in
            builder.uuid = ci.uuid
        }
        
        self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call", isError: false)
        let theCall = ci.accept(options: acceptOptions, delegate: self)
        self.sendPhoneCallEvents(description: "Answer|\(theCall.from ?? "")|\(theCall.to ?? "")\(formatCustomParams(params: ci.customParameters))", isError: false)
        self.call = theCall
        self.callKitCompletionCallback = completionHandler
        self.callInvite = nil
        
        completionHandler(true)
    }
    
    // MARK: - FlutterStreamHandler
    
    public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
    
    // MARK: - Event Sending
    
    private func sendPhoneCallEvents(description: String, isError: Bool) {
        NSLog("[TwilioVoice] \(description)")
        
        DispatchQueue.main.async {
            guard let eventSink = self.eventSink else { return }
            
            if isError {
                eventSink(FlutterError(code: "unavailable", message: description, details: nil))
            } else {
                eventSink(description)
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String, type == "twilio-missed-call", let user = userInfo["From"] as? String {
            self.callTo = user
            if let to = userInfo["To"] as? String {
                self.identity = to
            }
            makeCall(to: callTo)
            self.sendPhoneCallEvents(description: "ReturningCall|\(identity)|\(user)|Outgoing", isError: false)
        }
        completionHandler()
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call" {
            completionHandler([.alert])
        } else {
            completionHandler([])
        }
    }
}

// MARK: - Extensions

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else { return nil }
        return topViewController(for: rootViewController)
    }
    
    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else { return nil }
        guard let presentedViewController = rootViewController.presentedViewController else {
            return rootViewController
        }
        switch presentedViewController {
        case is UINavigationController:
            let navigationController = presentedViewController as! UINavigationController
            return topViewController(for: navigationController.viewControllers.last)
        case is UITabBarController:
            let tabBarController = presentedViewController as! UITabBarController
            return topViewController(for: tabBarController.selectedViewController)
        default:
            return topViewController(for: presentedViewController)
        }
    }
}

extension UserDefaults {
    public func optionalBool(forKey defaultName: String) -> Bool? {
        if let value = value(forKey: defaultName) {
            return value as? Bool
        }
        return nil
    }
}

extension Data {
    var hexString: String {
        return map { String(format: "%02.2hhx", $0) }.joined()
    }
}
