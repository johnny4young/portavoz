#!/usr/bin/env swift

// Reads each speech family of the public dictation corpus aloud into the default
// microphone. Recordings stay in the private output directory; nothing is uploaded.

import AVFoundation
import Darwin
import Foundation

struct Corpus: Decodable {
    struct Family: Decodable {
        let id: String
        let cohort: String
        let audioKind: String
        let acceptedTexts: [String]
    }
    let families: [Family]
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(EXIT_FAILURE)
}

private func prompt(_ text: String) -> String {
    print(text, terminator: " ")
    fflush(stdout)
    return (readLine() ?? "q").trimmingCharacters(in: .whitespaces).lowercased()
}

private var output: URL?
private var redo: Set<String> = []
private var corpusPath = "Fixtures/DictationValidation/public-synthetic-v1.json"
private var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--output": output = arguments.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
    case "--redo": arguments.next().map { _ = redo.insert($0) }
    case "--corpus": corpusPath = arguments.next() ?? corpusPath
    default: fail("usage: record-dictation-field-corpus.swift --output DIR [--redo FAMILY]... [--corpus PATH]")
    }
}
guard let output else { fail("--output is required") }

guard let data = FileManager.default.contents(atPath: corpusPath),
      let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else {
    fail("run from the repository root, or pass --corpus")
}
let families = corpus.families.filter { $0.audioKind == "speech" }

let access = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .audio) { granted = $0; access.signal() }
access.wait()
guard granted else { fail("microphone access was denied for this terminal") }

do {
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch {
    fail("cannot create the output directory")
}

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
]
print("Read each sentence as you would dictate it. Enter starts and stops; s skips; q quits.")
for (index, family) in families.enumerated() {
    let destination = output.appendingPathComponent(family.id + ".field.wav")
    if FileManager.default.fileExists(atPath: destination.path), !redo.contains(family.id) { continue }
    print("\n[\(index + 1)/\(families.count)] \(family.cohort)\n  \(family.acceptedTexts[0])")
    var kept = false
    while !kept {
        switch prompt("Enter to record:") {
        case "q": exit(EXIT_SUCCESS)
        case "s": kept = true; continue
        default: break
        }
        let partial = output.appendingPathComponent(".\(family.id).recording.wav")
        try? FileManager.default.removeItem(at: partial)
        guard let recorder = try? AVAudioRecorder(url: partial, settings: settings),
              recorder.record(forDuration: 110) else { fail("the microphone could not start recording") }
        _ = prompt("Recording… Enter to stop:")
        let seconds = recorder.currentTime
        recorder.stop()
        let answer = prompt(String(format: "%.1f s. Enter keeps it, r records again:", seconds))
        guard answer != "r" else { try? FileManager.default.removeItem(at: partial); continue }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            kept = true
        } catch {
            fail("cannot save the recording")
        }
    }
}
print("\nDone. Build the manifest with scripts/dictation_field_corpus.py build --audio-root \(output.path)")
