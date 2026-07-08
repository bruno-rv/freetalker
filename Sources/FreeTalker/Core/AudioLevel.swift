import Foundation

/// Cheap diagnostics for captured audio — peak amplitude and RMS (root-mean-square) level.
/// Used to detect near-silent captures (e.g. a stale mic TCC grant delivering zeros) without
/// needing to inspect the WAV file by ear.
enum AudioLevel {
    static func peakAndRMS(_ samples: [Float]) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return (peak, rms)
    }
}
