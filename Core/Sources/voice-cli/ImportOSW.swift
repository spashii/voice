import Foundation
import VoiceCore

// voice-cli import-osw [PATH] [--db PATH]
//     copies OpenSuperWhisper's recordings into Voice's history, as dictations with origin
//     "imported", for use as a test set. PATH is OpenSuperWhisper's support folder (the one
//     with recordings.sqlite), by default ~/Library/Application Support/ru.starmel.OpenSuperWhisper.
//     Running it again adds nothing that is already there. With --db the WAVs go to a
//     recordings folder beside that database, so a trial run never touches Voice's own.

func importOpenSuperWhisper(_ arguments: [String], dbPath: String?) -> Never {
    guard arguments.count <= 1 else {
        FileHandle.standardError.write(Data("usage: voice-cli import-osw [PATH] [--db PATH]\n".utf8))
        exit(1)
    }
    let folder = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? OpenSuperWhisperImport.defaultFolder
    let database = dbPath.map { URL(fileURLWithPath: $0) } ?? Paths.database
    let recordings = dbPath == nil
        ? Paths.recordings : database.deletingLastPathComponent().appending(path: "recordings", directoryHint: .isDirectory)
    do {
        let store = try Store(url: database)
        let counts = try OpenSuperWhisperImport.run(folder: folder, store: store, recordings: recordings)
        print("imported \(counts.imported), skipped \(counts.skipped) (no WAV), already present \(counts.alreadyPresent)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("voice-cli import-osw: \(error)\n".utf8))
        exit(1)
    }
}
