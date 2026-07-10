@preconcurrency import AVFoundation
import Foundation

// ponytail: debug harness only, not shipped in the real hot-key pipeline. Lets
// `--record-test <seconds>` exercise the REAL live-mic path (AudioCapture's AVAudioEngine tap +
// converter) end-to-end from the command line, to isolate whether live capture delivers silence
// independent of TCC context/UI. Upgrade path: none planned.
enum DebugRecordTest {
    static func runAndExit(seconds: Double) -> Never {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        FileHandle.standardError.write("[record-test] mic authorizationStatus.rawValue=\(micStatus.rawValue)\n".data(using: .utf8)!)

        let capture = AudioCapture()
        let engine = WhisperKitEngine()
        Task {
            do {
                try capture.start(deviceUID: nil)
                FileHandle.standardError.write("[record-test] capturing for \(seconds)s…\n".data(using: .utf8)!)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let samples = capture.stop()
                let (peak, rms) = AudioLevel.peakAndRMS(samples)
                FileHandle.standardError.write("[record-test] samples=\(samples.count) peak=\(peak) rms=\(rms)\n".data(using: .utf8)!)

                let statusTask = Task {
                    var last = ""
                    while !Task.isCancelled {
                        let current = await MainActor.run { engine.statusText }
                        if current != last {
                            FileHandle.standardError.write("[whisperkit] \(current)\n".data(using: .utf8)!)
                            last = current
                        }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                let output = try await engine.transcribe(samples: samples, forcedLanguage: nil)
                statusTask.cancel()
                print("samples: \(samples.count)")
                print("peak: \(peak)")
                print("rms: \(rms)")
                print("language: \(output.language)")
                print("transcript: \(output.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                exit(0)
            } catch {
                FileHandle.standardError.write("[record-test] error: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    }
}
