import CSQLite
import Foundation

enum MediaPipelineStage: String, CaseIterable, Sendable, Equatable {
    case decode
    case transcribe
    case diarize
    case finalize
}

extension TranscriptionJobStore {
    func completedMediaStages(jobID: UUID) throws -> Set<MediaPipelineStage> {
        let statement = try mediaPrepare("SELECT stage FROM media_job_stages WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        mediaBind(jobID.uuidString, 1, statement)
        var stages: Set<MediaPipelineStage> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
               let stage = MediaPipelineStage(rawValue: value) { stages.insert(stage) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw mediaSQLError() }
        return stages
    }

    func updateMediaProgress(jobID: UUID, progress: Double) throws {
        let statement = try mediaPrepare("""
        UPDATE transcription_jobs SET progress = MAX(progress, ?), updated_at = ?
        WHERE id = ? AND kind = 'media_import' AND state = 'processing';
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, min(1, max(0, progress.isFinite ? progress : 0)))
        sqlite3_bind_double(statement, 2, clock.now.timeIntervalSince1970)
        mediaBind(jobID.uuidString, 3, statement)
        try mediaStep(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func persistDecodedMedia(jobID: UUID, derivedAudioPath: String) throws {
        try mediaTransaction {
            try requireProcessingMediaJob(jobID)
            let file = try mediaPrepare("INSERT OR IGNORE INTO media_derived_files (job_id, path) VALUES (?, ?);")
            defer { sqlite3_finalize(file) }
            mediaBind(jobID.uuidString, 1, file); mediaBind(derivedAudioPath, 2, file); try mediaStep(file)
            try insertMediaCheckpoint(jobID: jobID, stage: .decode)
        }
    }

    func persistTranscript(jobID: UUID, segments: [TranscriptSegment]) throws {
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw JobStoreError.corruptData("Invalid transcript segment interval")
        }
        try mediaTransaction {
            try requireProcessingMediaJob(jobID)
            try deleteRows("transcript_segments", jobID: jobID)
            let statement = try mediaPrepare("INSERT INTO transcript_segments (job_id, ordinal, start_time, end_time, transcript) VALUES (?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            for (ordinal, segment) in segments.enumerated() {
                mediaBind(jobID.uuidString, 1, statement); sqlite3_bind_int(statement, 2, Int32(ordinal))
                sqlite3_bind_double(statement, 3, segment.start); sqlite3_bind_double(statement, 4, segment.end)
                mediaBind(segment.text, 5, statement); try mediaStep(statement)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try insertMediaCheckpoint(jobID: jobID, stage: .transcribe)
        }
    }

    func persistSpeakerTurns(jobID: UUID, turns: [SpeakerTurn]) throws {
        guard turns.allSatisfy({ !$0.speakerID.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw JobStoreError.corruptData("Invalid speaker turn interval")
        }
        try mediaTransaction {
            try requireProcessingMediaJob(jobID)
            try deleteRows("speaker_turns", jobID: jobID)
            let statement = try mediaPrepare("INSERT INTO speaker_turns (job_id, ordinal, speaker_id, start_time, end_time) VALUES (?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            for (ordinal, turn) in turns.enumerated() {
                mediaBind(jobID.uuidString, 1, statement); sqlite3_bind_int(statement, 2, Int32(ordinal)); mediaBind(turn.speakerID, 3, statement)
                sqlite3_bind_double(statement, 4, turn.start); sqlite3_bind_double(statement, 5, turn.end); try mediaStep(statement)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try insertMediaCheckpoint(jobID: jobID, stage: .diarize)
        }
    }

    func transcriptSegments(jobID: UUID) throws -> [TranscriptSegment] {
        let statement = try mediaPrepare("SELECT start_time, end_time, transcript FROM transcript_segments WHERE job_id = ? ORDER BY ordinal;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var values: [TranscriptSegment] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { values.append(.init(start: sqlite3_column_double(statement, 0), end: sqlite3_column_double(statement, 1), text: String(cString: sqlite3_column_text(statement, 2)))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }; return values
    }

    func speakerTurns(jobID: UUID) throws -> [SpeakerTurn] {
        let statement = try mediaPrepare("SELECT speaker_id, start_time, end_time FROM speaker_turns WHERE job_id = ? ORDER BY ordinal;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var values: [SpeakerTurn] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { values.append(.init(speakerID: String(cString: sqlite3_column_text(statement, 0)), start: sqlite3_column_double(statement, 1), end: sqlite3_column_double(statement, 2))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }; return values
    }

    func finalizeMediaImport(jobID: UUID) throws {
        try mediaTransaction {
            try requireProcessingMediaJob(jobID)
            try insertMediaCheckpoint(jobID: jobID, stage: .finalize)
            let statement = try mediaPrepare("""
            UPDATE transcription_jobs SET state = 'ready', progress = 1, failure_stage = NULL,
                failure_message = NULL, updated_at = ?, completed_at = ?
            WHERE id = ? AND kind = 'media_import' AND state = 'processing';
            """)
            defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
            sqlite3_bind_double(statement, 1, now); sqlite3_bind_double(statement, 2, now); mediaBind(jobID.uuidString, 3, statement)
            try mediaStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
        }
    }

    func queueMediaImportRetry(jobID: UUID) throws {
        let statement = try mediaPrepare("""
        UPDATE transcription_jobs SET state = 'queued', failure_stage = NULL, failure_message = NULL,
            updated_at = ?, completed_at = NULL
        WHERE id = ? AND kind = 'media_import' AND state IN ('failed', 'cancelled');
        """)
        defer { sqlite3_finalize(statement) }; sqlite3_bind_double(statement, 1, clock.now.timeIntervalSince1970); mediaBind(jobID.uuidString, 2, statement)
        try mediaStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func deleteMediaImport(jobID: UUID, fileManager: FileManager) throws {
        guard let current = try job(id: jobID), current.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        let statement = try mediaPrepare("SELECT path FROM media_derived_files WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var paths: [String] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { paths.append(String(cString: sqlite3_column_text(statement, 0))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }
        for path in paths where path != current.source.reference && fileManager.fileExists(atPath: path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw JobStoreError.corruptData("A media-derived path is not a file")
            }
            try fileManager.removeItem(atPath: path)
        }
        try mediaTransaction {
            for table in ["speaker_names", "speaker_segments", "speaker_turns", "transcript_segments", "media_job_stages", "media_derived_files", "job_attempts"] { try deleteRows(table, jobID: jobID) }
            let delete = try mediaPrepare("DELETE FROM transcription_jobs WHERE id = ? AND kind = 'media_import';")
            defer { sqlite3_finalize(delete) }; mediaBind(jobID.uuidString, 1, delete); try mediaStep(delete)
            guard sqlite3_changes(handle) == 1 else { throw JobStoreError.jobNotFound }
        }
    }

    private func insertMediaCheckpoint(jobID: UUID, stage: MediaPipelineStage) throws {
        let statement = try mediaPrepare("INSERT OR IGNORE INTO media_job_stages (job_id, stage, completed_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement); mediaBind(stage.rawValue, 2, statement)
        sqlite3_bind_double(statement, 3, clock.now.timeIntervalSince1970); try mediaStep(statement)
    }
    private func requireProcessingMediaJob(_ id: UUID) throws { guard let value = try job(id: id), value.kind == .mediaImport, value.state.kind == .processing else { throw JobStoreError.invalidTransition } }
    private func deleteRows(_ table: String, jobID: UUID) throws { let statement = try mediaPrepare("DELETE FROM \(table) WHERE job_id = ?;"); defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement); try mediaStep(statement) }
    private func mediaTransaction(_ body: () throws -> Void) throws { try mediaExecute("BEGIN IMMEDIATE;"); do { try body(); try mediaExecute("COMMIT;") } catch { try? mediaExecute("ROLLBACK;"); throw error } }
    private func mediaPrepare(_ sql: String) throws -> OpaquePointer { var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw mediaSQLError() }; return statement }
    private func mediaStep(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw mediaSQLError() } }
    private func mediaExecute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw mediaSQLError() } }
    private func mediaSQLError() -> DatabaseError { .sqlFailed(String(cString: sqlite3_errmsg(handle))) }
    private func mediaBind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
}
