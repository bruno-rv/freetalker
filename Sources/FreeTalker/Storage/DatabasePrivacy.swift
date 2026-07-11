import Darwin
import Foundation
import CSQLite

enum DatabasePrivacy {
    static func prepare(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let existed = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !existed || directory.lastPathComponent == "FreeTalker" {
            guard chmod(directory.path, S_IRWXU) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        }
    }

    static func secureOpenedDatabase(_ database: OpaquePointer, url: URL) throws {
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        guard sqlite3_exec(database, "PRAGMA secure_delete=ON;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(database)))
        }
        for suffix in ["-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path), chmod(path, S_IRUSR | S_IWUSR) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
        }
    }
}
