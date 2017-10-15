//
//  AudioController.swift
//  Beets
//
//  Created by Aditya Sawhney on 6/15/16.
//  Copyright © 2016 Druid, LLC. All rights reserved.
//

import CoreAudioKit
import AVFoundation

/**
 Manages recording and playing back sound.
 */
class AudioController: NSObject {
    
    private static var _sharedInstance: AudioController?
    static var sharedInstance: AudioController {
        if _sharedInstance == nil {
            _sharedInstance = AudioController()
        }
        return _sharedInstance!
    }
    
    let outputBus: UInt32 = 0
    let inputBus: UInt32 = 1
    
    let graphSampleRate = 44100.00
    
    var audioGraph: AUGraph!
    var playing: Bool = false

    var recordingEnabled: Bool = true
    
    // io: Records and plays back.
    var ioNode: AUNode!
    var fpNode: AUNode!
    var mxNode: AUNode!
    
    var ioUnit: AudioUnit!
    var fpUnit: AudioUnit!
    var mxUnit: AudioUnit!
    
    var mAudioRecFileRef: ExtAudioFileRef!
    
    var audioFormat: AudioStreamBasicDescription!
    var mixerFormat: AudioStreamBasicDescription!
    var filePlayerFormat: AudioStreamBasicDescription!
    
    var mBackingTrackFile: AudioFileID!
    
    var backingTrackURL: URL!
    var hasBackingTrack: Bool {
        return backingTrackURL != nil
    }
    
    var tickDuration: TimeInterval = 1.0
    var tick: Int = 0
    var ticksPerBeat: Int = 4
    
    var startTime: Double = 0.0
    var needsStartTime: Bool = true
    
    class func checkStatus(_ status: Int32) {
        if (status != 0) {
            print("Status \(status)")
        }
    }
    
    /**
     Creates an AudioController with default settings.
     */
    override init() {
        super.init()
        
        audioFormat = AudioStreamBasicDescription()
        audioFormat.mSampleRate         = graphSampleRate
        audioFormat.mFormatID           = kAudioFormatLinearPCM
        audioFormat.mFormatFlags        = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        audioFormat.mFramesPerPacket    = 1
        audioFormat.mChannelsPerFrame   = 1
        audioFormat.mBitsPerChannel     = 16
        audioFormat.mBytesPerPacket     = 2
        audioFormat.mBytesPerFrame      = 2
        
        let session = AVAudioSession.sharedInstance()
                // set preferred buffer size (Adjusts latency)
//        let audioBufferSize = 0.023220
        let audioBufferSize = 0.005
        do {
            try session.setPreferredIOBufferDuration(audioBufferSize)
        } catch {
            print("Error setting buffer size")
        }
    
        setupGraph()
    }
    
    /**
     Sets up a backing track. The backing track will be played back during
     recording and its output will be mixed with the microphone input before
     being saved to disk.
     
     - parameters:
         - url: The local URL of the backing track saved to disk.
     */
    func setBackingTrack(url: URL) {
        var tempFileID: AudioFileID?
        backingTrackURL = url
        var status = AudioFileOpenURL(url as CFURL, AudioFilePermissions.readPermission, 0, &tempFileID)
        if status != noErr { print("Error opening backing track file \(status)"); return; }
        mBackingTrackFile = tempFileID
        
        status = AudioUnitSetProperty(fpUnit,
                                      kAudioUnitProperty_ScheduledFileIDs,
                                      kAudioUnitScope_Global,
                                      0,
                                      &mBackingTrackFile,
                                      UInt32(MemoryLayout<AudioFileID>.size))
        if status != noErr { print("Error setting backing track \(status)"); return; }
        
        var numPackets: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(mBackingTrackFile,
                             kAudioFilePropertyAudioDataPacketCount,
                             &propSize,
                             &numPackets)
        if status != noErr { print("Error getting packet count \(status)"); return; }
        
        var fileASBD: AudioStreamBasicDescription! = AudioStreamBasicDescription()
        var asbdPropSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(mBackingTrackFile,
                                      kAudioFilePropertyDataFormat,
                                      &asbdPropSize,
                                      &fileASBD)
        if status != noErr { print("Error getting backing file format \(status)"); return; }
        
        var audioTimeStamp = AudioTimeStamp()
        audioTimeStamp.mFlags = AudioTimeStampFlags.sampleTimeValid
        audioTimeStamp.mSampleTime = 0
        var idk: AnyObject? = nil
        var region: ScheduledAudioFileRegion = ScheduledAudioFileRegion(mTimeStamp: audioTimeStamp,
                                                                        mCompletionProc: nil,
                                                                        mCompletionProcUserData: UnsafeMutableRawPointer(&idk),
                                                                        mAudioFile: mBackingTrackFile,
                                                                        mLoopCount: UINT32_MAX,
                                                                        mStartFrame: 0,
                                                                        mFramesToPlay: UINT32_MAX)
        
        status = AudioUnitSetProperty(fpUnit,
                                      kAudioUnitProperty_ScheduledFileRegion,
                                      kAudioUnitScope_Global,
                                      0,
                                      &region,
                                      UInt32(MemoryLayout<ScheduledAudioFileRegion>.size))
        if status != noErr { print("Error scheduling file region \(status)"); return; }
        
        var defaultVal: UInt32 = 0
        status = AudioUnitSetProperty(fpUnit,
                                      kAudioUnitProperty_ScheduledFilePrime,
                                      kAudioUnitScope_Global,
                                      0,
                                      &defaultVal,
                                      UInt32(MemoryLayout<UInt32>.size))
        if status != noErr { print("Error setting scheduledfileprime \(status)"); return; }
        
        var startTime: AudioTimeStamp = AudioTimeStamp()
        memset(&startTime, 0, MemoryLayout<AudioTimeStamp>.size)
        startTime.mFlags = AudioTimeStampFlags.sampleTimeValid
        startTime.mSampleTime = -1
        status = AudioUnitSetProperty(fpUnit,
                                      kAudioUnitProperty_ScheduleStartTimeStamp,
                                      kAudioUnitScope_Global,
                                      0,
                                      &startTime,
                                      UInt32(MemoryLayout<AudioTimeStamp>.size))
        if status != noErr { print("Error setting backing track start time \(status)"); return; }
        
    }
    
    /**
     Creates a file to be recorded to.
     */
    func prepareRecordingAudioFile(url: CFURL) {
        var mixerASBD: AudioStreamBasicDescription?
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(mxUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &mixerASBD,
                                      &propSize)
        mixerFormat = mixerASBD
        
        var fileRef: ExtAudioFileRef?
        var audioFormatPointer = audioFormat!
        if mixerFormat != nil {
            audioFormatPointer = mixerFormat!
        }
        
        status = ExtAudioFileCreateWithURL(url,
                                               kAudioFileCAFType, &audioFormatPointer, nil, 1, &fileRef)
        if status != noErr {
            print("Error creating recording file \(status)")
        }
        
        self.mAudioRecFileRef = fileRef
        status = ExtAudioFileSetProperty(mAudioRecFileRef, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &mixerASBD)
        status = ExtAudioFileWriteAsync(mAudioRecFileRef, 0, nil)
    }
    
    /**
     Closes the recording file.
     */
    func stopRecording(timer: Timer?) {
        let status = ExtAudioFileDispose(mAudioRecFileRef)
        print("OSStatus(ExtAudioFileDispose): \(status)")
    }
    
    /**
     Handles recording errors and updating the tick number.
     */
    var renderNotify: AURenderCallback = {(inRefCon: UnsafeMutableRawPointer,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
        
        var audioController = AudioController.sharedInstance
        if audioController.needsStartTime {
            audioController.startTime = inTimeStamp.pointee.mSampleTime / 44100.00
            audioController.needsStartTime = false
        }
        
        if ioActionFlags.pointee.contains(AudioUnitRenderActionFlags.unitRenderAction_PostRender) {
            if audioController.recordingEnabled {
                var status = ExtAudioFileWriteAsync(audioController.mAudioRecFileRef, inNumberFrames, ioData!)
                if status != noErr { print("Error writing audio: \(status)") }
                return status
            }
        } else {
            var timeInSeconds = (inTimeStamp.pointee.mSampleTime / 44100.00) - audioController.startTime
//            print(timeInSeconds)
            
            audioController.tick = Int(floor(timeInSeconds / audioController.tickDuration)) % audioController.ticksPerBeat
        }
        
        return noErr
    }
    
}

// MARK: - Functions
extension AudioController {
    
    /**
     Starts the graph, including playback or recording.
     */
    func startGraph() {
        let status = AUGraphStart(audioGraph)
        if status != noErr { print("Error starting audio graph \(status)"); return; }
        playing = true
        print("Started Audio Graph")
    }
    
    /**
     Stops the graph running, and resets data.
     */
    func stopGraph() {
        var isRunning: DarwinBoolean = false
        var status = AUGraphIsRunning(audioGraph, &isRunning)
        if status != noErr { print("Error checking if audiograph is running \(status)"); return; }
        
        if isRunning == true {
            status = AUGraphStop(audioGraph)
            if status != noErr { print("Error stopping Mixer Node \(status)"); return; }
            playing = false
        }
        
        stopRecording(timer: nil)
        tick = 0
        needsStartTime = true
    }
    
    /**
     Set up the audio graph, including setting up fpunit with files.
     Should be done after initialization but before start.
     */
    func setupGraph() {
        var tempGraph: AUGraph?
        var status = NewAUGraph(&tempGraph)
        audioGraph = tempGraph
        
        if status != noErr { print("Error initialitizing graph \(status)"); return; }
        
        var ioDesc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_RemoteIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
        
        var mxDesc = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
                                               componentSubType: kAudioUnitSubType_MultiChannelMixer,
                                               componentManufacturer: kAudioUnitManufacturer_Apple,
                                               componentFlags: 0,
                                               componentFlagsMask: 0)
        
        var fpDesc = AudioComponentDescription()
        fpDesc.componentType = kAudioUnitType_Generator
        fpDesc.componentSubType = kAudioUnitSubType_AudioFilePlayer
        fpDesc.componentManufacturer = kAudioUnitManufacturer_Apple
        
        var tempNode: AUNode = AUNode()
        status = AUGraphAddNode(audioGraph, &ioDesc, &tempNode)
        if status != noErr { print("Error initialitizing ioNode \(status)"); return; }
        ioNode = tempNode
        
        status = AUGraphAddNode(audioGraph, &mxDesc, &tempNode)
        if status != noErr { print("Error initialitizing Mixer Node \(status)"); return; }
        mxNode = tempNode
        
        status = AUGraphAddNode(audioGraph, &fpDesc, &tempNode)
        if status != noErr { print("Error initialitizing File Player Node \(status)"); return; }
        fpNode = tempNode
        
        status = AUGraphOpen(audioGraph)
        if status != noErr { print("Error opening Graph \(status)"); return; }
        
        var tempIOUnit: AudioUnit?
        status = AUGraphNodeInfo(audioGraph,
                                 ioNode,
                                 nil,
                                 &tempIOUnit)
        if status != noErr { print("Error obtaining ioUnit \(status)"); return; }
        ioUnit = tempIOUnit
        
        setupIOUnit(ioUnit: ioUnit)
        
        var tempMXUnit: AudioUnit?
        status = AUGraphNodeInfo(audioGraph,
                                 mxNode,
                                 nil,
                                 &tempMXUnit)
        if status != noErr { print("Error obtaining mxUnit \(status)"); return; }
        mxUnit = tempMXUnit
        
        setupMXUnit(mxUnit: mxUnit)
        
        var tempFPUnit: AudioUnit?
        status = AUGraphNodeInfo(audioGraph,
                                 fpNode,
                                 nil,
                                 &tempFPUnit)
        if status != noErr { print("Error obtaining fpUnit \(status)"); return; }
        fpUnit = tempFPUnit
        
        setupFPUnit(fpUnit: fpUnit)
        
        connectGraph()
        
        // DEBUG::
//        CAShow(&audioGraph)
        // END DEBUG
        
        status = AUGraphInitialize(audioGraph)
        if status != noErr { print("Error initializing graph \(status)"); return; }
    }
    
    /**
     Connects the nodes of the graph as follows:
     
     `FilePlayer -> Mixer`
     
     `Mixer -> IO Output`
     
     `IO Input -> Mixer`
     
     This way output from the FilePlayer is routed to playback & also to the recording.
     Input from IO is mixed with the FP output in the Mixer node and then saved to disk and outputted for monitoring.
     */
    private func connectGraph() {
        var status = AUGraphConnectNodeInput(audioGraph,
                                             fpNode,
                                             0,
                                             mxNode,
                                             1)
        if status != noErr { print("Error connecting fp to mx \(status)"); return; }
        
        status = AUGraphConnectNodeInput(audioGraph,
                                         mxNode,
                                         0,
                                         ioNode,
                                         0)
        
        if status != noErr { print("Error connecting mx back to io \(status)"); return; }
        
        status = AUGraphConnectNodeInput(audioGraph, ioNode, 1, mxNode, 0)
    }
    
    /**
     Sets up the FilePlayer to read from disk.
     */
    private func setupFPUnit(fpUnit: AudioUnit) {
        var asbd: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(fpUnit,
                                          kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output,
                                          0,
                                          &asbd,
                                          &propSize)
        if status != noErr { print("Error getting fpunit stream format \(status)"); return; }
        
        asbd.mSampleRate = graphSampleRate
        asbd.mChannelsPerFrame = 1
        
        filePlayerFormat = asbd
        
        status = AudioUnitSetProperty(fpUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr { print("Error setting fpunit stream format \(status)"); return; }
        
        status = AudioUnitSetProperty(mxUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      1,
                                      &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr { print("Error setting mxunit fp input stream format \(status)"); return; }
    }
    
    /**
     Sets up the Mixer unit.
     */
    private func setupMXUnit(mxUnit: AudioUnit) {
        
        var busCount: UInt32 = 2
        let micBus: UInt32   = 0
        let fpBus: UInt32    = 1
        
        var status = AudioUnitSetProperty(mxUnit,
                                          kAudioUnitProperty_ElementCount,
                                          kAudioUnitScope_Input,
                                          0,
                                          &busCount,
                                          UInt32(MemoryLayout<UInt32>.size));
        if status != noErr { print("Error setting mxUnit busCount \(status)"); return; }
        
        var maxFramesPerSlice: UInt32 = 4096
        status = AudioUnitSetProperty(mxUnit,
                                      kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &maxFramesPerSlice,
                                      UInt32(MemoryLayout<UInt32>.size))
        if status != noErr { print("Error setting mxUnit maxfps \(status)"); return; }
        
        status = AudioUnitSetProperty (mxUnit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input,
                                       micBus,
                                       &audioFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr { print("Error setting mxUnit mic Streamformat \(status)"); return; }
        
        var tempSampleRate = graphSampleRate
        status = AudioUnitSetProperty(mxUnit,
                                      kAudioUnitProperty_SampleRate,
                                      kAudioUnitScope_Output,
                                      0,
                                      &tempSampleRate,
                                      UInt32(MemoryLayout<Double>.size))
        if status != noErr { print("Error setting mxUnit output sample rate \(status)"); return; }
        
        AudioUnitAddRenderNotify(mxUnit, renderNotify, nil);
    }
    
    /**
     Sets up the IO unit to record to the mixer then output from the mixer.
     */
    private func setupIOUnit(ioUnit: AudioUnit) {
        let ioUnitInputBus: AudioUnitElement = 1
        let ioUnitOutputBus: AudioUnitElement = 0
        var enableInput: UInt32 = 1
        
        AudioUnitSetProperty(ioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             ioUnitInputBus,
                             &enableInput,
                             UInt32(MemoryLayout<Int>.size))
        
        AudioUnitSetProperty(ioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             ioUnitInputBus,
                             &audioFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        AudioUnitSetProperty(ioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Global,
                             ioUnitOutputBus,
                             &audioFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
    }
}

public extension ScheduledAudioFileRegion {
    /**
     Adapter needed for Swift initialization.
     */
    init(mTimeStamp: AudioTimeStamp, mCompletionProc: ScheduledAudioFileRegionCompletionProc?, mCompletionProcUserData: UnsafeMutableRawPointer, mAudioFile: OpaquePointer, mLoopCount: UInt32, mStartFrame: Int64, mFramesToPlay: UInt32) {
        self.mTimeStamp = mTimeStamp
        self.mCompletionProc = mCompletionProc
        self.mCompletionProcUserData = mCompletionProcUserData
        self.mAudioFile = mAudioFile
        self.mLoopCount = mLoopCount
        self.mStartFrame = mStartFrame
        self.mFramesToPlay = mFramesToPlay
    }
}
