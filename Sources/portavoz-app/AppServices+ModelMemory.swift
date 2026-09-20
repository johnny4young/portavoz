extension AppServices {
    /// Drops idle speech-model weights. In-flight preparation owns its result
    /// until the workflow schedules a later release.
    func releaseRecordingEngines() {
        _ = releaseLiveSpeechRuntime()
        _ = releaseDiarizationRuntime()
        settleModelsState()
    }

    /// The balanced profile keeps the measured reuse window; lightweight
    /// releases promptly, but the existing adapters still refuse active leases.
    func scheduleRecordingEnginesRelease() {
        modelIdleReleaseScheduler.schedule(.recording, profile: modelMemoryPreferences.profile) { [weak self] in
            guard let self, !self.refines.isRunning else { return }
            self.releaseRecordingEngines()
        }
    }

    func setModelMemoryProfile(_ profile: AppModelMemoryPreferences.Profile) {
        modelMemoryPreferences.setProfile(profile)
        scheduleRecordingEnginesRelease()
        scheduleWhisperRelease()
        scheduleMLXRelease()
    }

    func settleModelsState() {
        if transcriber != nil, diarizationRuntime != nil {
            modelsState = .ready
        } else if liveSpeechRuntimeLoad == nil, diarizationRuntimeLoad == nil {
            modelsState = .unknown
        }
    }
}
