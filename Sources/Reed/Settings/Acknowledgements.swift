import Foundation

/// One readable notice. `id` is the path relative to the bundle's resource
/// root, so identity survives a title change and two notices with identical
/// text stay distinct entries.
struct Acknowledgement: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
}

/// Why a notice, or the whole set, could not be read. Each case carries enough
/// to say something specific to the user rather than "something went wrong".
enum AcknowledgementProblem: Error, Equatable {
    case noResourceRoot
    case missingDirectory(String)
    case emptyInventory(String)
    case missingAsset(String)
    case unreadable(String)
    case notUTF8(String)
    case empty(String)

    var message: String {
        switch self {
        case .noResourceRoot:
            return "Reed could not locate its own resources."
        case .missingDirectory(let path):
            return "The notices folder is missing from this copy of Reed (\(path))."
        case .emptyInventory(let path):
            return "No notices are packaged in this copy of Reed (\(path))."
        case .missingAsset(let path):
            return "A notice that should ship with Reed is missing: \(path)."
        case .unreadable(let path):
            return "This notice could not be read: \(path)."
        case .notUTF8(let path):
            return "This notice is not readable text: \(path)."
        case .empty(let path):
            return "This notice is empty in this copy of Reed: \(path)."
        }
    }
}

/// Reads the notices `build-app.sh` packages, from the installed app's own
/// resources. Nothing here knows what the texts say: the inventory is whatever
/// is on disk, so a notice added to the packaging mapping later shows up
/// without touching this file or the UI.
struct AcknowledgementsStore {
    /// Injected in tests; the app passes `Bundle.main.resourceURL`. Never a
    /// working directory, checkout path or network location.
    let resourceRoot: URL?

    /// Where the packager writes the dependency notices.
    static let noticesDirectory = "ThirdPartyLicenses"

    /// Texts that ship beside their asset rather than in the notices folder.
    /// Verified against a built bundle; absence is reported, not skipped.
    static let assetNotices: [(path: String, title: String)] = [
        ("Fonts/OFL-Geist.txt", "Geist font"),
        ("Fonts/OFL-GeistMono.txt", "Geist Mono font"),
        ("Models/LICENSE-FastEnhancer.txt", "FastEnhancer denoise model"),
    ]

    init(resourceRoot: URL? = Bundle.main.resourceURL) {
        self.resourceRoot = resourceRoot
    }

    /// Display names for the filenames Reed packages today. A filename that is
    /// not listed still appears — `fallbackTitle` makes something readable out
    /// of it — so the list can never quietly omit a newly packaged notice.
    static let titles: [String: String] = [
        "Aptabase-LICENSE.txt": "Aptabase",
        "FluidAudio-LICENSE.txt": "FluidAudio",
        "FluidAudio-fastcluster-LICENSE.txt": "FluidAudio · fastcluster",
        "FluidAudio-vbx-LICENSE.txt": "FluidAudio · VBx",
        "KeyboardShortcuts-LICENSE.txt": "KeyboardShortcuts",
        "onnxruntime-LICENSE.txt": "ONNX Runtime",
        "onnxruntime-swift-wrapper-LICENSE.txt": "ONNX Runtime · Swift wrapper",
        "onnxruntime-ThirdPartyNotices.txt": "ONNX Runtime · third-party notices",
        "Parakeet-speech-model-attribution.txt": "Speech model attribution",
        "Sentry-LICENSE.txt": "Sentry",
        "Sentry-apsl-header-reference.txt": "Sentry · APSL reference",
        "Sentry-fishhook-notice.txt": "Sentry · fishhook notice",
        "Sentry-webkit-derived-notices.txt": "Sentry · WebKit-derived notices",
        "Sparkle-LICENSE.txt": "Sparkle",
    ]

    /// A readable name for a filename nobody has mapped yet: drop the
    /// extension and the LICENSE/notice boilerplate, and let separators breathe.
    static func fallbackTitle(for filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
        for suffix in ["-LICENSE", "-LICENCE", "-NOTICE", "-notices", "-notice"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        let spaced = stem.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return spaced.isEmpty ? filename : spaced
    }

    /// The notices this copy of Reed carries, plus anything that should have
    /// been there and was not. Entries stay usable when one is missing: a
    /// partial list with a warning beats an empty screen.
    func inventory() -> (entries: [Acknowledgement], problems: [AcknowledgementProblem]) {
        guard let root = resourceRoot else { return ([], [.noResourceRoot]) }
        var problems: [AcknowledgementProblem] = []
        var entries: [Acknowledgement] = []

        let dir = root.appendingPathComponent(Self.noticesDirectory, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let visible = names.filter { !$0.hasPrefix(".") }
            if visible.isEmpty {
                problems.append(.emptyInventory(Self.noticesDirectory))
            }
            // Sorted by filename: a stable order that does not depend on the
            // filesystem's enumeration order.
            for name in visible.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                entries.append(Acknowledgement(
                    id: "\(Self.noticesDirectory)/\(name)",
                    title: Self.titles[name] ?? Self.fallbackTitle(for: name),
                    url: dir.appendingPathComponent(name)
                ))
            }
        } else {
            problems.append(.missingDirectory(Self.noticesDirectory))
        }

        for asset in Self.assetNotices {
            let url = root.appendingPathComponent(asset.path)
            if FileManager.default.fileExists(atPath: url.path) {
                entries.append(Acknowledgement(id: asset.path, title: asset.title, url: url))
            } else {
                problems.append(.missingAsset(asset.path))
            }
        }

        if entries.isEmpty && problems.isEmpty {
            problems.append(.emptyInventory(Self.noticesDirectory))
        }
        return (entries, problems)
    }

    /// The text of one notice, or why it could not be shown. Callers must
    /// render the failure — showing the previously selected text under a new
    /// title would misattribute a licence.
    func text(for entry: Acknowledgement) -> Result<String, AcknowledgementProblem> {
        guard let data = try? Data(contentsOf: entry.url) else {
            return .failure(.unreadable(entry.id))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.notUTF8(entry.id))
        }
        // A zero-byte or whitespace-only file would render as a blank reader
        // that looks like success (review 2026-09-16). Non-empty text is
        // returned verbatim, surrounding whitespace included.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.empty(entry.id))
        }
        return .success(text)
    }
}
