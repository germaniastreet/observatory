import Foundation

enum CognitiveObservationDetector {
    static let engineVersion = "2.1"

    static func detect(session: ReflectionSession) -> [ObservationEvent] {
        SignalLibraryDetectionEngine.detect(
            session: session,
            libraries: PersistentSignalLibraryStore.shared.activeLibraries,
            domain: .cognitive
        )
    }
}
