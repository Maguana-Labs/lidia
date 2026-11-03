import Foundation

/// Picks the speech-to-text engine for users who haven't chosen one, based on language.
///
/// The live Parakeet model is English-only, so defaulting everyone to it gives Spanish (or
/// any non-English) speakers a garbled live transcript.
enum STTEngineDefaults {
    /// - Parameters:
    ///   - languageCode: ISO 639 code such as "en" or "es"; nil means unknown (treated as English).
    ///   - appleOnDeviceAvailable: whether Apple Speech can recognise the language on this Mac.
    static func recommendedEngine(languageCode: String?, appleOnDeviceAvailable: Bool) -> AppSettings.STTEngineType {
        let code = (languageCode ?? "").lowercased()
        if code.isEmpty || code == "en" {
            return .parakeet
        }
        // On-device, live, punctuated, and nothing to download.
        if appleOnDeviceAvailable {
            return .appleSpeech
        }
        // Multilingual fallback when Apple can't recognise the language on-device.
        return .whisperKit
    }

    /// Recommendation for the STT language setting, or the user's preferred language when
    /// that setting is empty ("system default").
    static func recommendedEngine(
        sttLanguage: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppSettings.STTEngineType {
        let identifier = sttLanguage.isEmpty ? (preferredLanguages.first ?? "en") : sttLanguage
        let locale = Locale(identifier: identifier)
        let code = locale.language.languageCode?.identifier
        if code == nil || code == "en" {
            return .parakeet
        }
        return recommendedEngine(
            languageCode: code,
            appleOnDeviceAvailable: AppleSpeechEngine.supportsOnDeviceRecognition(for: locale)
        )
    }
}
