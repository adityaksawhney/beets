//
//  TapTempo.swift
//  Beets
//
//  Created by Aditya Sawhney on 6/14/16.
//  Copyright © 2016 Druid, LLC. All rights reserved.
//

import Foundation

/**
 Takes taps and dynamically computes the average tempo for the most recent 4 taps.
 */
class TapTempo {
    
    /**
     Timeout used when tempo has not been established
     */
    let hardTimeout: TimeInterval
    
    /**
     Currently registered tempo.
     */
    var tempo: Int?
    
    /**
     If a tempo has been established, returns 4 beats at that tempo. Otherwise
     returns `hardTimeout`.
     */
    var timeOut: TimeInterval {
        if let tempo = tempo {
            return 240.0 / Double(tempo)
        } else { return hardTimeout }
    }
    
    /**
     Number of taps required to register a tempo.
     */
    private let minTaps: Int
    
    /**
     Maximum number of taps to consider in calculating a tempo.
     */
    private let maxTaps: Int
    
    /**
     Timestamps of taps. Capped at `maxTaps` entries.
     */
    private var taps: [Date] = []
    
    /**
     Public accessor for number of taps registered.
     */
    var tapCount: Int {
        return taps.count
    }
    
    /**
     Initializes a new TapTempo.
     
     - Parameters:
         - timeOut: Time to wait before cancelling tempo registration.
         - minimumTaps: Minimum number of taps to register a tempo.
         - maximumTaps: Maximum taps considered when computing a tempo.
     */
    init(timeOut: TimeInterval, minimumTaps: Int, maximumTaps: Int) {
        hardTimeout = timeOut
        minTaps = minimumTaps
        maxTaps = maximumTaps
    }
    
    /**
     Registers a tap by recording the current time.
     
     - Returns: The current tempo, if registered, or `nil` if minimumTaps has not been reached yet.
     */
    func addTap() -> Int? {
        let thisTap = Date()
        if let lastTap = taps.last {
            // Check if there was an existing tap registered, if so, check for timeout.
            if thisTap.timeIntervalSince(lastTap) > timeOut {
                taps.removeAll()
                tempo = nil
            }
        }
        taps.append(thisTap)
        guard taps.count >= minTaps else { return nil } // Not enough taps, return nil.
        if taps.count > maxTaps { taps.removeFirst() }
        guard let firstTap = taps.first else { return nil }
        let avgIntervals = thisTap.timeIntervalSince(firstTap) / Double(taps.count - 1)
        tempo = Int(60.0 / avgIntervals)
        return tempo
    }
}
