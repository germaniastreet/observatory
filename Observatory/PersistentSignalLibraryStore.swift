import Foundation

final class PersistentSignalLibraryStore {
    static let shared = PersistentSignalLibraryStore()

    private let fileName = "observatory_signal_libraries_v1.json"
    private let queue = DispatchQueue(label: "observatory.signal-library-store")
    private var cachedLibraries: [SignalLibrary] = []

    private init() {
        loadOrSeed()
    }

    var activeLibraries: [SignalLibrary] {
        queue.sync {
            cachedLibraries.filter { $0.isEnabledByDefault }
        }
    }

    func librariesSnapshot() -> [SignalLibrary] {
        queue.sync {
            cachedLibraries
        }
    }

    func resetToDefaults() {
        queue.sync {
            cachedLibraries = SignalLibraryDefaults.defaultLibraries
            saveLocked()
        }
    }

    func setLibraryEnabled(id: String, isEnabled: Bool) {
        queue.sync {
            guard let index = cachedLibraries.firstIndex(where: { $0.id == id }) else { return }
            cachedLibraries[index].isEnabledByDefault = isEnabled
            cachedLibraries[index].updatedAt = Date()
            saveLocked()
        }
    }

    func replaceLibraries(_ libraries: [SignalLibrary]) {
        queue.sync {
            cachedLibraries = libraries
            saveLocked()
        }
    }

    func exportJSONData() throws -> Data {
        try JSONEncoder.signalLibraryEncoder.encode(librariesSnapshot())
    }

    func importJSONData(_ data: Data) throws {
        let imported = try JSONDecoder.signalLibraryDecoder.decode([SignalLibrary].self, from: data)
        replaceLibraries(imported)
    }

    private func loadOrSeed() {
        queue.sync {
            let url = storeURL()

            guard FileManager.default.fileExists(atPath: url.path) else {
                cachedLibraries = SignalLibraryDefaults.defaultLibraries
                saveLocked()
                return
            }

            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder.signalLibraryDecoder.decode([SignalLibrary].self, from: data)

                if decoded.isEmpty {
                    cachedLibraries = SignalLibraryDefaults.defaultLibraries
                } else {
                    cachedLibraries = decoded
                    mergeMissingDefaultLibrariesLocked()
                }

                saveLocked()
            } catch {
                cachedLibraries = SignalLibraryDefaults.defaultLibraries
                saveLocked()
            }
        }
    }

    private func mergeMissingDefaultLibrariesLocked() {
        let existingIDs = Set(cachedLibraries.map { $0.id })

        for defaultLibrary in SignalLibraryDefaults.defaultLibraries {
            if !existingIDs.contains(defaultLibrary.id) {
                cachedLibraries.append(defaultLibrary)
            }
        }
    }

    private func saveLocked() {
        do {
            let url = storeURL()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try JSONEncoder.signalLibraryEncoder.encode(cachedLibraries)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Signal library store save failed: \(error.localizedDescription)")
        }
    }

    private func storeURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("Observatory", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private extension JSONEncoder {
    static var signalLibraryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var signalLibraryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
