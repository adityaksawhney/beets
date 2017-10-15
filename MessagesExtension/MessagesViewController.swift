//
//  MessagesViewController.swift
//  MessagesExtension
//
//  Created by Aditya Sawhney on 6/14/16.
//  Copyright © 2016 Druid, LLC. All rights reserved.
//

import UIKit
import Messages
import AVFoundation
import AudioToolbox

/**
 Core UI class for Beets. A UI experiment to explore the power of 1 button.
 There's also a back button.
 
 - TODO:
     - Change headphone prompt. Maybe we can't playback through the speakers when recording but at least find elegant way to tell them.
     - Make layout clearer / more obvious what's going on. Move away from haptic feedback?
     - Chunk functionality better
 */
class MessagesViewController: MSMessagesAppViewController, AVAudioRecorderDelegate {
    
    let audioController = AudioController.sharedInstance
    let baseURL = "http://druid.haus"
    let api = API()
    
    private var thisContext = 0
    
    enum RecordingState: Int {
        case NeedsTempo, RecordingTempo, HasTempo, CountIn, Recording, ReviewForSend // Core progression (left -> right)
        case HasBackingTrack // Replacement for HasTempo. Skips first 2 states when this is the case because BackingTrack includes tempo info.
        case Downloading, Uploading
        case Playing
    }
    enum MessageURLComponent: String {
        case Tempo = "Tempo"
        case AccessURL = "AccessURL"
    }
    
    @IBOutlet weak var instructionLabel: UILabel!
    @IBOutlet weak var undoButton: UIButton!
    @IBOutlet weak var beetButton: UIButton!
    @IBOutlet weak var shareButton: UIButton!
    @IBOutlet weak var countImageView: UIImageView!
    
    private let tapTempo = TapTempo(timeOut: 2.0, minimumTaps: 4, maximumTaps: 4)
    private var tapTimer: Timer?
    
    private var hapticTimer: Timer? {
        willSet {
            hapticTimer?.invalidate()
        }
    }
    
    private var countInTimer: Timer?
    private var countInTick: Int = 3
    
    private var displayLink: CADisplayLink?
    
    private var tempo: Int?
    private var tickInterval: TimeInterval? {
        guard let tempo = tempo else { return nil }
        return 60.0 / Double(tempo)
    }
    
    var recordingShouldEnd = false
    private var tick: Int?
    private var state: RecordingState! {
        didSet {
            configureFor(state)
            lastState = oldValue
        }
    }
    private var lastState: RecordingState?
    
    private var recordingSession: AVAudioSession!
    private var player: AVAudioPlayer!
    
    private let shareURL: URL = {
        let audioFilename = MessagesViewController.getDocumentsDirectory().appendingPathComponent("Untitled Beet.caf")
        let audioURL = URL(fileURLWithPath: audioFilename)
        return audioURL
    }()
    private let recordingURL: URL = {
        let audioFilename = MessagesViewController.getDocumentsDirectory().appendingPathComponent("newBeet.caf")
        let audioURL = URL(fileURLWithPath: audioFilename)
        return audioURL
    }()
    private let backingTrackURL: URL = {
        let audioFilename = MessagesViewController.getDocumentsDirectory().appendingPathComponent("backingBeet.caf")
        let audioURL = URL(fileURLWithPath: audioFilename)
        return audioURL
    }()
    private var shouldUseBackingTrack: Bool = false
    
    private var headphonesAttached: Bool = true {
        didSet {
            beetButton.isEnabled = headphonesAttached
            undoButton.isEnabled = headphonesAttached
        }
    }
    
    private let sendAnimationImages = UIImage.animationImageSet(withPrefix: "Send")
    private let playAnimationImages = UIImage.animationImageSet(withPrefix: "Play")
    private let downloadAnimationImages = UIImage.animationImageSet(withPrefix: "Download")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("loaded1")
        // Do any additional setup after loading the view.
        state = .NeedsTempo
        
        recordingSession = AVAudioSession.sharedInstance()
        
        do {
            try self.recordingSession.setCategory(AVAudioSessionCategoryPlayAndRecord)
            try self.recordingSession.setActive(true)
//            try self.recordingSession.overrideOutputAudioPort(.speaker)
            
            self.recordingSession.requestRecordPermission({ (allowed) in
                if !allowed {
                    // Get rid of UI because we can't record.
                    self.beetButton.isEnabled = false
                    self.instructionLabel.text = "Beets needs permission to access your microphone."
                }
            })
        } catch {
            DispatchQueue.main.async {
                self.beetButton.isEnabled = false
                self.instructionLabel.text = "An error occurred."
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.audioRouteDidChange), name: NSNotification.Name.AVAudioSessionRouteChange, object: recordingSession)
    }
    
    // MARK: - Conversation Handling
    
    override func willBecomeActive(with conversation: MSConversation) {
        // Called when the extension is about to move from the inactive to active state.
        // This will happen when the extension is about to present UI.
        
        // Use this method to configure the extension and restore previously stored state.
        print(conversation.selectedMessage)
    }
    
    override func willResignActive(with conversation: MSConversation) {
        stopTempoHaptic()
        stopPlayback()
    }
    
    override func didBecomeActive(with conversation: MSConversation) {
        print("Did Become Active")
        if let message = conversation.selectedMessage {
            loadMessage(message)
        }
        
        headphoneCheck()
    }
    
    override func didResignActive(with conversation: MSConversation) {
        // Called when the extension is about to move from the active to inactive state.
        // This will happen when the user dismisses the extension, changes to a different
        // conversation or quits Messages.
        
        // Use this method to release shared resources, save user data, invalidate timers,
        // and store enough state information to restore your extension to its current state
        // in case it is terminated later.
        print("Did Resign Active")
        
        tapTimer?.invalidate()
        stopTempoHaptic()
        if audioController.playing {
            stopRecording(success: false)
        }
    }
   
    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        print("Did Receive Message")
        // Called when a message arrives that was generated by another instance of this
        // extension on a remote device.
        // Use this method to trigger UI updates in response to the message.
    }
    
    override func willSelect(_ message: MSMessage, conversation: MSConversation) {
        print("Will Select Message")
        super.willSelect(message, conversation: conversation)
    }
    
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        print("Did Select Message")
        super.didSelect(message, conversation: conversation)
        loadMessage(message)
    }
    
    override func didStartSending(_ message: MSMessage, conversation: MSConversation) {
        // Called when the user taps the send button.
        print(message.url)
        
        state = .NeedsTempo
    }
    
    override func didCancelSending(_ message: MSMessage, conversation: MSConversation) {
        // Called when the user deletes the message without sending it.
        // Use this to clean up state related to the deleted message.
        state = .NeedsTempo
    }
    
    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        // Called before the extension transitions to a new presentation style.
        // Use this method to prepare for the change in presentation style.
    }
    
    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        // Called after the extension transitions to a new presentation style.
    
        // Use this method to finalize any behaviors associated with the change in presentation style.
    }
    
    // MARK: - Tap Handling
    
    /**
     Handler for main button. Check state and handle accordingly, moving forward in the `RecordingState` progression.
     */
    @IBAction func didTapBeetButton(_ sender: AnyObject) {
        switch state! {
        case .NeedsTempo, .RecordingTempo:
            addTempoTap()
            break
        case .HasTempo:
            stopPlayback()
            prepareToRecord(backingTrack: nil)
            startRecording()
            break
        case .CountIn:
            break
        case .Recording:
            recordingShouldEnd = true
            break
        case .ReviewForSend:
            populateMessage()
            stopPlayback()
            break
        case .HasBackingTrack:
            stopPlayback()
            prepareToRecord(backingTrack: backingTrackURL)
            startRecording()
            break
        case .Downloading:
            break
        case .Uploading:
            break
        case .Playing:
            break
        }
    }
    
    /**
     Handler for undo button. Check state and handle accordingly, generally moving backward in the `RecordingState` progression.
     */
    @IBAction func didTapUndoButton(_ sender: AnyObject) {
        switch state! {
        case .NeedsTempo, .RecordingTempo:
            break
        case .HasTempo:
            tempo = nil
            state = .NeedsTempo
            break
        case .CountIn:
            break
        case .Recording:
            break
        case .ReviewForSend:
            stopPlayback() // These calls MUST be sequenced like this or the audio file gets closed.
            if shouldUseBackingTrack {
                state = .HasBackingTrack
            } else {
                state = .HasTempo
            }
            break
        case .HasBackingTrack:
            stopPlayback()
            state = .HasTempo
            break
        case .Downloading:
            api.downloadTask?.cancel()
            break
        case .Uploading:
            api.uploadTask?.cancel()
            break
        case .Playing:
            stopPlayback()
            break
        }
    }
    
    /**
     Based on current state, prepares the recorded file or the loaded backing track to share.
     */
    @IBAction func didTapShareButton(_ sender: AnyObject) {
        switch state! {
        case .HasBackingTrack:
            share(fileAtURL: backingTrackURL)
        case .ReviewForSend:
            share(fileAtURL: recordingURL)
        default:
            break
        }
    }
    
    /**
     Shares the file at the given URL. First attempts to copy the file to `shareURL` to standardize its name. If this fails, share from the given URL.
     */
    private func share(fileAtURL fileURL: URL) {
        requestPresentationStyle(.expanded)
        let manager = FileManager.default
        let fileArray: [URL]
        do {
            if manager.fileExists(atPath: shareURL.path) {
                try manager.removeItem(at: shareURL)
            }
            try manager.copyItem(at: fileURL, to: shareURL)
            
            print("Sharing file from shareURL")
            fileArray = [shareURL]
        } catch {
            print("Error removing or copying file")
            print(error)
            fileArray = [fileURL]
        }
        
        let activityViewController = UIActivityViewController(activityItems: fileArray, applicationActivities: nil)
        self.present(activityViewController, animated: true, completion: nil)
    }
    
    /**
     Loads the given message. Parses it for tempo and backing track information,
     downloads the track if needed, and sets up the current state accordingly.
     */
    private func loadMessage(_ message: MSMessage) {
        print("Loading message with url: \(message.url)")
        guard let url = message.url else {
            return
        }
        
        var messageTempo: Int? = nil // Default tempo just in case
        var accessURL: URL? = nil
        
        parse(messageURL: url, toTempo: &messageTempo, toAccessURL: &accessURL)
        
        guard let remoteURL = accessURL else { return }
        if messageTempo == nil { messageTempo = 60 }
        
        self.state = .Downloading
        api.downloadItem(atURL: remoteURL, toFile: backingTrackURL) { (success) in
            if success {
                print("Successfully downloaded track")
                self.shouldUseBackingTrack = true
                self.tempo = messageTempo
                self.state = .HasBackingTrack
                self.startPlayback(audioURL: self.backingTrackURL)
            } else {
                print("Failed to download file")
                self.state = .NeedsTempo
            }
        }
    }
    
    /**
     Parses messageURL and stores its data to given `tempo` and `accessURL`
     `inout` variables.
     */
    private func parse(messageURL url: URL, toTempo tempo: inout Int?, toAccessURL accessURL: inout URL?) {
        guard let components = NSURLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems else {
                fatalError("The message contains an invalid URL")
        }
        
        for queryItem in queryItems {
            guard let value = queryItem.value else { continue }
            switch queryItem.name {
            case MessageURLComponent.Tempo.rawValue:
                tempo = Int(value)
            case MessageURLComponent.AccessURL.rawValue:
                accessURL = URL(string: value)
            default:
                break
            }
        }
    }
    
    /**
     Adds a tap to the `TapTempo`. If this registers a tempo, set a timer for
     the tapTempo's timeout, and set the state to `.RecordingTempo`. Otherwise,
     just update the Beet image.
     */
    private func addTempoTap() {
        if let tappedTempo = tapTempo.addTap() {
            tempo = Int(tappedTempo)
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(timeInterval: tapTempo.timeOut, target: self, selector: #selector(tapTempoDidTimeout), userInfo: nil, repeats: false)
            state = .RecordingTempo
        } else {
            tempo = nil
//            state = .NeedsTempo
            countImageView.image = UIImage(named: "BeetCountFill-\(tapTempo.tapCount)")
        }
    }
    
    /**
     If a tempo has been registered, proceed to the next state.
     */
    @objc
    private func tapTempoDidTimeout(timer: Timer) {
        guard tempo != nil else { return }
        if case state = RecordingState.RecordingTempo {
            state = .HasTempo
        }
    }
    
    /**
     Sets everything up to record. Creates a file and sets a backing track.
     */
    private func prepareToRecord(backingTrack: URL? = nil) {
        let audioURL = recordingURL
        audioController.tickDuration = tickInterval ?? 1.0
        audioController.prepareRecordingAudioFile(url: audioURL as CFURL)
        if let backingTrack = backingTrack {
            audioController.setBackingTrack(url: backingTrack)
        }
    }
    
    /**
     Sets up a `CADisplayLink` so that we can update the Beet icon in sync with
     the tempo, then starts a count-in.
     */
    private func startRecording() {
        player?.stop()
        displayLink = CADisplayLink(target: self, selector: #selector(screenDidRefresh))
        displayLink?.add(to: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        
        state = .Recording
        startCountIn()
    }
    
    /**
     Sets up a timer to run a count-in.
     */
    private func startCountIn() {
        stopTempoHaptic()
        countInTimer = Timer.scheduledTimer(timeInterval: tickInterval ?? 1.0, target: self, selector: #selector(countInTick(sender:)), userInfo: nil, repeats: true)
        countInTick(sender: nil)
        state = .CountIn
    }
    
    /**
     Updates the beet button and the counter icon, or, if the count-in is ending
     then starts recording. Also triggers a haptic tick for feedback.
     */
    @objc
    private func countInTick(sender: Timer?) {
        tempoTick(sender: sender)
        if countInTick == -1 {
            audioController.startGraph()
            state = .Recording
            sender?.invalidate()
            countInTick = 3
        } else {
            beetButton.setImage(UIImage(named: "BeetButton-Recording\(countInTick)"), for: [])
            countImageView.image = UIImage(named: "BeetCount-\(4 - countInTick)")
            countInTick = countInTick - 1
        }
    }
    
    /**
     Stops the `AudioController` and the `displayLink`, progresses state if all
     went well.
     */
    private func stopRecording(success: Bool) {
        audioController.stopGraph()
        recordingShouldEnd = false
        beetButton.setImage(#imageLiteral(resourceName: "BeetButton"), for: [])
        displayLink?.invalidate()
        if success {
            state = .ReviewForSend
            startPlayback(audioURL: recordingURL)
        } else {
            state = .HasTempo
        }
    }
    
    /**
     Handler for display refresh. Checks for tick number in `audioController`
     and updates the Beet button accordingly.
     */
    @objc
    private func screenDidRefresh() {
        if !audioController.playing { return; }
        if audioController.tick != self.tick {
            if audioController.tick == 0 && recordingShouldEnd {
                stopRecording(success: true)
                displayLink?.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
            } else {
                beetButton.setImage(UIImage(named: "BeetButton-Recording\(audioController.tick)"), for: [])
                countImageView.image = UIImage(named: "BeetCount-\(audioController.tick + 1)")
                self.tick = audioController.tick
            }
        }
    }
    
    /**
     Uploads the recorded item, and then creates and inserts a message into the
     send box.
     */
    private func populateMessage() {
        self.state = .Uploading
        api.uploadItem(atURL: recordingURL, withName: "\(UUID().uuidString).\(recordingURL.pathExtension)") { (accessURL) in
            self.state = .ReviewForSend;
            guard let accessURL = accessURL else { return }
            let conversation = self.activeConversation
            let message = MSMessage()
            message.url = self.getMessageURL(accessURL: accessURL)
            print(message.url)
            message.layout = self.getMessageLayout()
            conversation?.insert(message, completionHandler: nil)
        }
    }

    /**
     Plays back the recorded track. Treats it as a backing track.
     */
    private func startPlayback(audioURL: URL) {
        if audioController.playing { return }
        audioController.setBackingTrack(url: audioURL)
        audioController.recordingEnabled = false
        audioController.startGraph()
    }
    
    /**
     Stops playback of the recorded track. Treats it as a backing track.
     */
    private func stopPlayback() {
        if !audioController.playing { return }
        audioController.stopGraph()
        audioController.recordingEnabled = true
    }
    
    /**
     Handles early termination of the audioRecorder. Legacy code from audioRecorder?
     */
//    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
//        if !flag {
//            stopRecording(success: false)
//        }
//    }
    
    /**
     Handles attachment or detachment of headphones. Triggers another block
     if headphones are detached.
     */
    func audioRouteDidChange(notification: Notification) {
        if state == .Recording {
            if Thread.current.isMainThread {
                stopRecording(success: false)
            } else {
                DispatchQueue.main.sync {
                    stopRecording(success: false)
                }
            }
            
        } else {
            stopPlayback()
        }
        headphoneCheck()
    }
    
    /**
     Checks to see if headphones are connected, and if not, prevents the user
     from continuing.
     
     There are so many better ways to do this. (What was I thinking?)
     */
    private func headphoneCheck() {
        if !headphonesConnected() {
            let alertViewController = UIAlertController(title: "No Headphones Connected", message: "Beets only works with headphones connected. Using your phone's speakers can cause feedback loops and spoiled beets.", preferredStyle: .alert)
            
            alertViewController.addAction(UIAlertAction(title: "OK", style: .default) { (action) in
                DispatchQueue.main.async {
                    self.requestPresentationStyle(.compact)
                }
                if !self.headphonesConnected() {
                    self.instructionLabel.text = "Please connect headphones to continue."
                    self.headphonesAttached = false
                } else {
                    self.headphonesAttached = true
                }
            })
            present(alertViewController, animated: true, completion: {
                self.requestPresentationStyle(.expanded)
            })
        } else {
            DispatchQueue.main.async {
                self.configureFor(self.state)
                self.headphonesAttached = true
            }
        }
    }
    
    /**
     Convenience checker.
     */
    private func headphonesConnected() -> Bool {
        let availableOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
        for portDescription in availableOutputs {
            if portDescription.portType == AVAudioSessionPortHeadphones {
                return true
            }
        }
        return false
    }
    
    /**
     Handles UI for transition to a given state.
     */
    private func configureFor(_ state: RecordingState) {
        stopTempoHaptic()
        if beetButton.imageView?.isAnimating == true {
            beetButton.imageView?.stopAnimating(); beetButton.imageView?.animationImages = nil
        }
        switch state {
        case .NeedsTempo:
            beetButton.setImage(#imageLiteral(resourceName: "BeetButton-Metronome"), for: .normal)
            countImageView.image = #imageLiteral(resourceName: "BeetCount-0")
            instructionLabel.text = "Tap the beet to set your tempo."
            undoButton.isEnabled = false
            shareButton.isEnabled = false
            break
        case .RecordingTempo:
            beetButton.setImage(#imageLiteral(resourceName: "BeetButton-Metronome"), for: .normal)
            countImageView.image = #imageLiteral(resourceName: "BeetCountFill-4")
            instructionLabel.text = "Stop tapping to lock in tempo."
            undoButton.isEnabled = false
            shareButton.isEnabled = false
            break
        case .HasTempo:
            countImageView.image = #imageLiteral(resourceName: "BeetCount-0")
            beetButton.setImage(#imageLiteral(resourceName: "BeetButton"), for: .normal)
            instructionLabel.text = "Tap the beet to start recording."
            let backingTrackOrNil: URL? = shouldUseBackingTrack ? backingTrackURL : nil
            prepareToRecord(backingTrack: backingTrackOrNil)
            startTempoHaptic()
            undoButton.isEnabled = true
            shareButton.isEnabled = false
            break
        case .CountIn:
            undoButton.isEnabled = false
            shareButton.isEnabled = false
            instructionLabel.text = "Get ready!"
        case .Recording:
            undoButton.isEnabled = false
            shareButton.isEnabled = false
            instructionLabel.text = "Tap the beet to finish recording."
            break
        case .ReviewForSend:
            beetButton.setImage(#imageLiteral(resourceName: "BeetButton-Send"), for: .normal)
            beetButton.isHighlighted = false
            countImageView.image = #imageLiteral(resourceName: "BeetCount-0")
            undoButton.isEnabled = true
            shareButton.isEnabled = true
            instructionLabel.text = "Send your message to collaborate."
            break
        case .HasBackingTrack:
            beetButton.setImage(#imageLiteral(resourceName: "BeetButton"), for: .normal)
            undoButton.isEnabled = true
            shareButton.isEnabled = true
            instructionLabel.text = "Tap the beet to record another layer."
            let backingTrackOrNil: URL? = shouldUseBackingTrack ? backingTrackURL : nil
            prepareToRecord(backingTrack: backingTrackOrNil)
            startTempoHaptic()
        case .Downloading:
            shareButton.isEnabled = false
            instructionLabel.text = "Loading..."
            beetButton.imageView?.animationImages = self.downloadAnimationImages
            beetButton.imageView?.animationDuration = 1.0
            beetButton.imageView?.startAnimating()
        case .Uploading:
            shareButton.isEnabled = false
            instructionLabel.text = "Preparing message..."
            beetButton.imageView?.animationImages = self.sendAnimationImages
            beetButton.imageView?.animationDuration = 1.0
            beetButton.imageView?.startAnimating()
        case .Playing:
            shareButton.isEnabled = false
            instructionLabel.text = "Press Pause to continue."
            beetButton.imageView?.animationImages = self.playAnimationImages
            beetButton.imageView?.animationDuration = 1.0
            beetButton.imageView?.startAnimating()
        }
    }
    
    /**
     Starts rhythmic haptic feedback that indicates the tempo to the user.
     */
    private func startTempoHaptic() {
        if let tickInterval = tickInterval {
            tempoTick(sender: nil)
            hapticTimer?.invalidate()
            hapticTimer = Timer.scheduledTimer(timeInterval: tickInterval, target: self, selector: #selector(tempoTick(sender:)), userInfo: nil, repeats: true)
        }
    }
    
    /**
     Stops rhythmic haptic feedback.
     */
    private func stopTempoHaptic() {
        hapticTimer?.invalidate()
    }
    
    /**
     Play a single haptic tick.
     */
    @objc
    private func tempoTick(sender: Timer?) {
        AudioServicesPlaySystemSound(1519)
    }
    
    /**
     Create message URL using the remote URL of the recording to send.
     */
    private func getMessageURL(accessURL: String) -> URL {
        guard let components = NSURLComponents(string: baseURL) else {
            fatalError("Invalid base url")
        }
        
        let tempoQuery = URLQueryItem(name: MessageURLComponent.Tempo.rawValue, value: String(tempo!))
        let accessURLQuery = URLQueryItem(name: MessageURLComponent.AccessURL.rawValue, value: accessURL)
        components.queryItems = [tempoQuery, accessURLQuery]
        
        guard let url = components.url  else {
            fatalError("Invalid URL components.")
        }
        
        return url
    }
    
    /**
     Creates the template layout for a Beets message.
     */
    private func getMessageLayout() -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        if let activeConversation = activeConversation {
            layout.caption = "$\(activeConversation.localParticipantIdentifier.uuidString) sent a fresh Beet"
        } else {
            layout.caption = "You've received a fresh Beet"
        }
        layout.subcaption = "Tap to add a layer"
        return layout
    }

}

extension NSObject {
    /**
     Convenience getter for docs.
     */
    class func getDocumentsDirectory() -> NSString {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true) as [String]
        let documentsDirectory = paths[0]
        return documentsDirectory as NSString
    }
}
