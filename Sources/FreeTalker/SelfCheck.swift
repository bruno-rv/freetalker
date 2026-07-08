import CoreGraphics
import Foundation

/// Runnable without any test framework. This CLT-only environment (no Xcode.app) has no
/// working XCTest/swift-testing *runtime* — `Tests/FreeTalkerTests` compiles fine (proves the
/// code is correct Swift) but `swift test` fails to launch the test bundle because
/// Testing.framework's supporting dylibs aren't shipped outside Xcode. This duplicates those
/// same two checks (FTS roundtrip, template seeding) as a guaranteed-runnable verification:
///
///   swift run FreeTalker --self-check
///
/// See README.md "Running tests" for the full story.
/// Canned-transcript `TranscriptionEngine` for the pipeline contract check below — never
/// touches the microphone or a real model. See Round 1 Codex finding 14.
struct FakeTranscriptionEngine: TranscriptionEngine {
    let name = "FakeEngine"
    @MainActor var statusText: String { "Ready" }
    let cannedText: String

    func transcribe(samples: [Float]) async throws -> TranscriptionOutput {
        TranscriptionOutput(text: cannedText, language: "en")
    }
}

/// No-op `PostProcessor` for the pipeline contract check below — returns the transcript
/// unchanged so the check exercises the capture-to-transcript-to-Library-row contract without
/// depending on Apple Intelligence or a cloud LLM. See Round 1 Codex finding 14.
struct PassthroughPostProcessor: PostProcessor {
    func process(transcript: String, template: Template) async throws -> String {
        transcript
    }
}

/// Always-empty `PostProcessor` — exercises the empty-refined-output fallback contract in
/// `AppCoordinator.processDictation`. See Round 2 Codex finding 8.
struct EmptyPostProcessor: PostProcessor {
    func process(transcript: String, template: Template) async throws -> String {
        ""
    }
}

enum SelfCheck {
    static func runAndExit() -> Never {
        // `AppCoordinator.processDictation` is `@MainActor`, so the check below must run on the
        // main actor. `runAndExit()` itself is called synchronously from `FreeTalkerApp.init()`
        // on the main thread — blocking that thread (e.g. with a semaphore) while also needing
        // it to run a `@MainActor` Task would deadlock. Instead, run everything inside a
        // `@MainActor` Task and pump the main queue with `dispatchMain()` until it exits.
        Task { @MainActor in
            var failures: [String] = []

            let templates = Template.builtIns
            if templates.count != 4 {
                failures.append("expected 4 built-in templates, got \(templates.count)")
            }
            if !templates.contains(where: { $0.id == Template.defaultID }) {
                failures.append("default template id (\(Template.defaultID)) missing from built-ins")
            }
            if Set(templates.map(\.id)).count != templates.count {
                failures.append("duplicate template ids among built-ins")
            }

            // Mic device enumeration needs no permissions (reads CoreAudio device topology, not
            // audio) — verifies enumeration finds this machine's input devices and that a UID
            // round-trips back to the same AudioDeviceID, which is the contract AudioCapture
            // relies on to pin a configured microphone. See PLAN: closed-lid MacBook incident.
            let inputDevices = AudioInputDevices.enumerate()
            if inputDevices.isEmpty {
                failures.append("AudioInputDevices.enumerate() found no input devices")
            } else {
                print("SelfCheck: found \(inputDevices.count) input device(s): \(inputDevices.map(\.name).joined(separator: ", "))")
                let first = inputDevices[0]
                if AudioInputDevices.resolveID(forUID: first.uid) != first.id {
                    failures.append("AudioInputDevices UID round-trip failed for \(first.name) (uid=\(first.uid))")
                }
            }

            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let db = try Database(path: tempDir.appendingPathComponent("selfcheck.db"))
                let id = try db.insertDictation(
                    timestamp: Date(),
                    language: "en",
                    template: "Clean Dictation",
                    transcript: "the quick brown fox jumps over the lazy dog",
                    refined: "The quick brown fox jumps over the lazy dog.",
                    engine: "WhisperKit"
                )
                let hits = try db.searchDictations(query: "brown fox")
                if !hits.contains(where: { $0.id == id }) {
                    failures.append("FTS search for \"brown fox\" did not find the inserted row")
                }
                let misses = try db.searchDictations(query: "nonexistent-zzz-term")
                if misses.contains(where: { $0.id == id }) {
                    failures.append("FTS search matched a term that isn't in the row")
                }
            } catch {
                failures.append("Database round-trip threw: \(error)")
            }

            // Pipeline contract: exercises the *actual* AppCoordinator.processDictation pipeline
            // (the same method runPipeline calls) with a fake engine/processor, a no-CGEvent
            // insert hook, and a record hook pointed at a temp DB instead of the user's real
            // Library. See Round 2 Codex finding 8.
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                let db = try Database(path: tempDir.appendingPathComponent("pipeline-check.db"))

                let cannedSamples: [Float] = [0.1, -0.2, 0.05, 0.3]
                let fakeEngine = FakeTranscriptionEngine(cannedText: "the quick brown fox jumps over the lazy dog")
                let template = Template.builtIns.first!
                let recordToTempDB: (String, String, String, String, String) throws -> Void = { language, templateName, transcript, refined, engine in
                    try db.insertDictation(timestamp: Date(), language: language, template: templateName, transcript: transcript, refined: refined, engine: engine)
                }

                // (a) canned samples -> non-empty transcript -> refined lands in a Library row.
                let resultA = try await AppCoordinator.shared.processDictation(
                    samples: cannedSamples,
                    engine: fakeEngine,
                    engineName: fakeEngine.name,
                    template: template,
                    processor: PassthroughPostProcessor(),
                    insert: { _ in true },
                    record: recordToTempDB
                )
                if resultA.refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("pipeline contract: refined output was empty for a non-empty transcript")
                }
                let rows = try db.allDictations()
                if !rows.contains(where: { $0.transcript == resultA.transcript && $0.refined == resultA.refined }) {
                    failures.append("pipeline contract: Library row missing after processDictation")
                }

                // (b) empty-refined post-processor output falls back to the raw transcript.
                let resultB = try await AppCoordinator.shared.processDictation(
                    samples: cannedSamples,
                    engine: fakeEngine,
                    engineName: fakeEngine.name,
                    template: template,
                    processor: EmptyPostProcessor(),
                    insert: { _ in true },
                    record: recordToTempDB
                )
                if resultB.refined != resultB.transcript {
                    failures.append("pipeline contract: empty post-processor output did not fall back to the raw transcript")
                }
            } catch {
                failures.append("Pipeline contract check threw: \(error)")
            }

            failures.append(contentsOf: hotKeyChecks())

            if failures.isEmpty {
                print("SelfCheck PASSED (template seeding, FTS round-trip, pipeline contract, mic device enumeration, hotkey spec/matcher)")
                exit(0)
            } else {
                print("SelfCheck FAILED:")
                for failure in failures { print(" - \(failure)") }
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Pure-logic hotkey checks: HotKeySpec encode/decode roundtrip and the HotKeyMatcher
    /// state machine driven with synthetic (event kind, keycode, flags) sequences — no
    /// CGEvents, no permissions. Covers the three hotkey shapes: single modifier, modifier
    /// chord, and modifiers+key (plus a bare non-modifier key).
    private static func hotKeyChecks() -> [String] {
        var failures: [String] = []

        // Generic CGEventFlags bits (side-agnostic) and NX device bits (side-specific).
        let ctrl: UInt64 = CGEventFlags.maskControl.rawValue
        let alt: UInt64 = CGEventFlags.maskAlternate.rawValue
        let shift: UInt64 = CGEventFlags.maskShift.rawValue
        let cmd: UInt64 = CGEventFlags.maskCommand.rawValue
        let fn: UInt64 = CGEventFlags.maskSecondaryFn.rawValue
        let dLCtrl: UInt64 = 0x0001, dRCtrl: UInt64 = 0x2000
        let dLAlt: UInt64 = 0x0020, dRAlt: UInt64 = 0x0040
        let dLShift: UInt64 = 0x0002
        let dLCmd: UInt64 = 0x0008

        // Encode/decode roundtrip (both shapes).
        do {
            for spec in [HotKeySpec(modifiers: dLCtrl | dLAlt, keyCode: nil),
                         HotKeySpec(modifiers: dLCmd | dLShift, keyCode: 2),
                         HotKeySpec(modifiers: 0, keyCode: 105)] {
                let decoded = try JSONDecoder().decode(HotKeySpec.self, from: JSONEncoder().encode(spec))
                if decoded != spec {
                    failures.append("HotKeySpec roundtrip mismatch: \(spec) -> \(decoded)")
                }
            }
        } catch {
            failures.append("HotKeySpec roundtrip threw: \(error)")
        }

        func expect(_ matcher: inout HotKeyMatcher, _ label: String,
                    _ kind: KeyEventKind, keyCode: UInt16 = 0, flags: UInt64, isAutorepeat: Bool = false,
                    engaged: Bool = false, released: Bool = false, swallow: Bool = false) {
            let outcome = matcher.handle(kind, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
            let want = HotKeyMatcher.Outcome(engaged: engaged, released: released, swallow: swallow)
            if outcome != want {
                failures.append("matcher [\(label)]: got \(outcome), want \(want)")
            }
        }

        // Shape 1: single modifier (Right ⌥), device-level left/right-specific.
        var single = HotKeyMatcher(spec: HotKeySpec(modifiers: dRAlt, keyCode: nil))
        expect(&single, "single: left ⌥ must not engage", .flagsChanged, flags: alt | dLAlt)
        expect(&single, "single: left ⌥ release", .flagsChanged, flags: 0)
        expect(&single, "single: superset (⌥+⇧ from scratch) must not engage", .flagsChanged, flags: alt | dRAlt | shift | dLShift)
        expect(&single, "single: superset release", .flagsChanged, flags: 0)
        expect(&single, "single: right ⌥ engages", .flagsChanged, flags: alt | dRAlt, engaged: true)
        expect(&single, "single: extra ⇧ mid-hold keeps engaged", .flagsChanged, flags: alt | dRAlt | shift | dLShift)
        expect(&single, "single: dropping ⌥ releases", .flagsChanged, flags: shift | dLShift, released: true)

        // Shape 2: modifier chord (⌃⌥), side-agnostic.
        var chord = HotKeyMatcher(spec: HotKeySpec(modifiers: dLCtrl | dLAlt, keyCode: nil))
        expect(&chord, "chord: ⌃ alone must not engage", .flagsChanged, flags: ctrl | dLCtrl)
        expect(&chord, "chord: ⌃⌥ engages", .flagsChanged, flags: ctrl | alt | dLCtrl | dLAlt, engaged: true)
        expect(&chord, "chord: dropping ⌥ releases", .flagsChanged, flags: ctrl | dLCtrl, released: true)
        expect(&chord, "chord: all released", .flagsChanged, flags: 0)
        expect(&chord, "chord: right-side keys engage too (side-agnostic)", .flagsChanged, flags: ctrl | alt | dRCtrl | dRAlt, engaged: true)
        expect(&chord, "chord: adding ⌘ mid-hold keeps engaged", .flagsChanged, flags: ctrl | alt | cmd | dRCtrl | dRAlt | dLCmd)
        expect(&chord, "chord: dropping ⌃ releases", .flagsChanged, flags: alt | cmd | dRAlt | dLCmd, released: true)
        expect(&chord, "chord: superset (⌃⌥⌘ from scratch) must not engage", .flagsChanged, flags: ctrl | alt | cmd | dLCtrl | dLAlt | dLCmd)

        // Shape 3: modifiers+key (⌘D, keyCode 2) — engage/release swallow the keystroke.
        var combo = HotKeyMatcher(spec: HotKeySpec(modifiers: dLCmd, keyCode: 2))
        expect(&combo, "combo: D without ⌘ passes through", .keyDown, keyCode: 2, flags: 0)
        expect(&combo, "combo: wrong key with ⌘ passes through", .keyDown, keyCode: 3, flags: cmd | dLCmd)
        expect(&combo, "combo: ⌘⇧D (superset) must not engage", .keyDown, keyCode: 2, flags: cmd | shift | dLCmd | dLShift)
        expect(&combo, "combo: ⌘D engages and swallows", .keyDown, keyCode: 2, flags: cmd | dLCmd, engaged: true, swallow: true)
        expect(&combo, "combo: autorepeat swallowed, no transition", .keyDown, keyCode: 2, flags: cmd | dLCmd, isAutorepeat: true, swallow: true)
        expect(&combo, "combo: keyUp releases and swallows", .keyUp, keyCode: 2, flags: cmd | dLCmd, released: true, swallow: true)
        expect(&combo, "combo: re-engage", .keyDown, keyCode: 2, flags: cmd | dLCmd, engaged: true, swallow: true)
        expect(&combo, "combo: dropping ⌘ releases", .flagsChanged, flags: 0, released: true)
        expect(&combo, "combo: trailing keyUp still swallowed after modifier-drop release", .keyUp, keyCode: 2, flags: 0, swallow: true)

        // Shape 3b: bare non-modifier key (F13, keyCode 105). F-keys carry the Fn flag.
        var bare = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        expect(&bare, "bare: ⌘F13 must not engage", .keyDown, keyCode: 105, flags: cmd | dLCmd)
        expect(&bare, "bare: F13 engages despite Fn flag", .keyDown, keyCode: 105, flags: fn, engaged: true, swallow: true)
        expect(&bare, "bare: flagsChanged mid-hold keeps engaged", .flagsChanged, flags: shift | dLShift)
        expect(&bare, "bare: keyUp releases and swallows", .keyUp, keyCode: 105, flags: 0, released: true, swallow: true)

        // Display labels stay human-readable.
        if HotKeySpec(modifiers: dRAlt, keyCode: nil).displayLabel != "Right ⌥" {
            failures.append("displayLabel: single Right ⌥ should keep side-aware label")
        }
        if HotKeySpec(modifiers: dLCtrl | dLAlt, keyCode: nil).displayLabel != "⌃⌥" {
            failures.append("displayLabel: chord should render ⌃⌥")
        }
        if HotKeySpec(modifiers: dLCmd | dLShift, keyCode: 2).displayLabel != "⇧⌘D" {
            failures.append("displayLabel: combo should render ⇧⌘D, got \(HotKeySpec(modifiers: dLCmd | dLShift, keyCode: 2).displayLabel)")
        }
        if HotKeySpec(modifiers: 0, keyCode: 105).displayLabel != "F13" {
            failures.append("displayLabel: bare F13")
        }

        return failures
    }
}
