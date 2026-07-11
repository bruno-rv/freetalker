import Foundation
import Testing
@testable import FreeTalker

@Suite("Media import presentation")
struct MediaImportPresentationTests {
    @Test(arguments: ["wav", "m4a", "mp3", "mp4", "mov"])
    func supportedDropsAreOfferedToTheImporter(_ extension: String) {
        #expect(MediaImportPresentation.acceptsDrop(URL(fileURLWithPath: "/tmp/recording.\(`extension`)")))
    }

    @Test func renamedOrMislabeledFilesAreRejectedBeforeImport() {
        #expect(!MediaImportPresentation.acceptsDrop(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!MediaImportPresentation.acceptsDrop(URL(fileURLWithPath: "/tmp/movie.mov.txt")))
    }

    @Test func eachPipelineStageHasSpecificProgressCopy() {
        #expect(MediaImportPresentation.progress(stage: .decoding, overall: 0.125).label == "Extracting audio")
        #expect(MediaImportPresentation.progress(stage: .transcribing, overall: 0.375).label == "Transcribing locally")
        #expect(MediaImportPresentation.progress(stage: .diarizing, overall: 0.625).label == "Downloading speaker model or separating speakers")
        #expect(MediaImportPresentation.progress(stage: .finalizing, overall: 0.875).label == "Finishing import")
    }

    @Test func durableStateAndTranscriptControlActions() {
        #expect(MediaImportPresentation.actions(state: .queued, transcriptReady: false) == [.cancel])
        #expect(MediaImportPresentation.actions(state: .processing(stage: .diarizing), transcriptReady: true) == [.cancel, .export])
        #expect(MediaImportPresentation.actions(state: .failed(.init(stage: .diarizing, message: "offline")), transcriptReady: true) == [.retrySpeakerSeparation, .export, .delete])
        #expect(MediaImportPresentation.actions(state: .failed(.init(stage: .transcribing, message: "bad")), transcriptReady: false) == [.retry, .delete])
        #expect(MediaImportPresentation.actions(state: .cancelled, transcriptReady: true) == [.retry, .export, .delete])
        #expect(MediaImportPresentation.actions(state: .ready, transcriptReady: true) == [.export, .delete])
    }

    @Test func rawSpeakerIDsDriveImmediateRenameAndEmptyNameHasFallback() {
        let segment = AttributedTranscriptSegment(start: 0, end: 1, text: "Hello", speakerID: "cluster-42")
        #expect(MediaImportPresentation.displayName(speakerID: "cluster-42", names: [:], ordinal: 2) == "Speaker 2")
        #expect(MediaImportPresentation.displayName(speakerID: "cluster-42", names: ["cluster-42": ""], ordinal: 2) == "Speaker 2")
        let names = MediaImportPresentation.exportNames(speakerIDs: ["cluster-42"], names: ["cluster-42": "Ada"])
        for format in TranscriptFormat.allCases {
            #expect(TranscriptExporter().export([segment], format: format, speakerNames: names).contains("Ada"))
        }
    }

    @Test func exportIsUnavailableUntilTranscriptCheckpointExists() {
        #expect(!MediaImportPresentation.canExport(transcriptReady: false))
        #expect(MediaImportPresentation.canExport(transcriptReady: true))
    }

    @Test func localOnlyCopyIsExplicit() {
        #expect(MediaImportPresentation.localOnlyMessage.contains("stays on this Mac"))
        #expect(MediaImportPresentation.videoExtractionMessage.contains("audio"))
    }

    @Test func importedMediaRetentionDefaultsToSevenDaysAndCanBeChanged() {
        #expect(MediaImportRetention.default == .sevenDays)
        #expect(MediaImportRetention.thirtyDays.days == 30)
        #expect(MediaImportRetention.never.days == nil)
    }
}
