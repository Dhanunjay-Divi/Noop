import ImageIO
import StrandDesign
import SwiftUI
import WebKit
import WhoopStore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum StrengthExerciseMediaPresentation {
    case workout
    case detail
}

private struct StrengthExerciseMediaLayout: Layout {
    let aspectRatio: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width
            ?? subviews.first?.sizeThatFits(.unspecified).width
            ?? 320
        let width = max(0, proposedWidth)
        return CGSize(width: width, height: width / max(0.1, aspectRatio))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let childProposal = ProposedViewSize(
            width: bounds.width,
            height: bounds.height
        )
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: childProposal
            )
        }
    }
}

/// Animated form guidance for NOOP's built-in catalog, with a native fallback when licensed media
/// is not configured. The fallback keeps every workout usable without enlarging low-resolution media.
struct StrengthExerciseMotionView: View {
    let exercise: StrengthExerciseRow
    var showsTechniqueButton = true
    var presentation: StrengthExerciseMediaPresentation = .workout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("strength.exerciseMediaCompact.v2") private var mediaMinimized = true

    private var guide: StrengthExerciseGuide {
        StrengthExerciseGuidance.guide(for: exercise)
    }

    private var stageAspectRatio: CGFloat {
        switch (presentation, mediaMinimized) {
        case (.workout, true):
            3.45
        case (.workout, false):
            2.15
        case (.detail, _):
            2.15
        }
    }

    var body: some View {
        StrengthExerciseMediaLayout(aspectRatio: stageAspectRatio) {
            if let variant = guide.animationVariant {
                StrengthNativeExerciseMediaView(
                    exercise: exercise,
                    exerciseID: variant.rawValue,
                    source: StrengthExerciseNativeAssets.mediaSource(
                        for: variant.rawValue
                    ),
                    reduceMotion: reduceMotion,
                    minimized: mediaMinimized,
                    showsTechniqueButton: showsTechniqueButton,
                    showsSizeButton: presentation == .workout,
                    onToggleSize: { mediaMinimized.toggle() }
                )
            } else {
                StrengthExerciseFallbackMotionView(exercise: exercise)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strengthExerciseName(exercise))
    }
}

private struct StrengthExerciseFallbackMotionView: View {
    let exercise: StrengthExerciseRow

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(
                systemName: exercise.equipment == "bodyweight"
                    ? "figure.strengthtraining.traditional"
                    : "dumbbell.fill"
            )
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(StrandPalette.effortColor)
            .frame(width: 46, height: 46)
            .background(
                StrandPalette.effortColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(strengthExerciseName(exercise))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(strengthMediaDescriptor(exercise.primaryMuscle)) · "
                        + strengthMediaDescriptor(exercise.equipment)
                )
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceInset)
    }
}

private struct StrengthExerciseFormGuide: Decodable {
    let setup: String
    let movement: String
    let breathing: String
    let tempo: String
    let safety: String
}

struct StrengthExerciseMediaPolicy {
    static let minimumLicensedPixels = 360
    static let maximumDownloadBytes = 16 * 1_024 * 1_024

    static func licensedURL(template: String, mediaID: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              mediaID.range(
                of: #"^[A-Za-z0-9]+$"#,
                options: .regularExpression
              ) != nil
        else {
            return nil
        }

        let rendered: String
        if trimmed.contains("{id}") {
            rendered = trimmed.replacingOccurrences(of: "{id}", with: mediaID)
        } else {
            rendered = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/\(mediaID).gif"
        }
        guard let url = URL(string: rendered),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    static func accepts(width: Int, height: Int, minimumPixels: Int) -> Bool {
        width >= minimumPixels && height >= minimumPixels
    }
}

private struct StrengthExerciseMediaSource: Equatable {
    let url: URL
    let minimumPixels: Int
    let cacheKey: String
}

private enum StrengthExerciseNativeAssets {
    static let mediaIDs: [String: String] = decode("exercise-media") ?? [:]
    static let guides: [String: StrengthExerciseFormGuide] =
        decode("exercise-guidance") ?? [:]

    static func mediaSource(for exerciseID: String) -> StrengthExerciseMediaSource? {
        guard let mediaID = mediaIDs[exerciseID] else { return nil }

        if let bundled = strengthMotionResourceURL(
            forResource: mediaID,
            withExtension: "gif",
            subdirectory: "Media"
        ) {
            return StrengthExerciseMediaSource(
                url: bundled,
                minimumPixels: StrengthExerciseMediaPolicy.minimumLicensedPixels,
                cacheKey: "bundle-\(mediaID)"
            )
        }

        let configuredTemplate =
            Bundle.main.object(
                forInfoDictionaryKey: "NOOPStrengthMediaURLTemplate"
            ) as? String ?? ""
        if let configured = StrengthExerciseMediaPolicy.licensedURL(
            template: configuredTemplate,
            mediaID: mediaID
        ) {
            return StrengthExerciseMediaSource(
                url: configured,
                minimumPixels: StrengthExerciseMediaPolicy.minimumLicensedPixels,
                cacheKey: "licensed-\(mediaID)"
            )
        }

        #if DEBUG
        // The public ExerciseDB endpoint currently serves only 180 px GIFs. It is useful for explicit
        // simulator QA, but must never become the implicit production source.
        if ProcessInfo.processInfo.environment["NOOP_STRENGTH_DEMO_MEDIA"] == "1",
           let demo = URL(
               string: "https://static.exercisedb.dev/media/\(mediaID).gif"
           ) {
            return StrengthExerciseMediaSource(
                url: demo,
                minimumPixels: 180,
                cacheKey: "demo-\(mediaID)"
            )
        }
        #endif

        return nil
    }

    private static func decode<T: Decodable>(_ name: String) -> T? {
        guard let url = strengthMotionResourceURL(
            forResource: name,
            withExtension: "json"
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class StrengthExerciseMediaLoader: ObservableObject {
    enum Phase {
        case unavailable
        case loading
        case loaded(Data)
        case failed
    }

    @Published private(set) var phase: Phase = .unavailable

    func load(source: StrengthExerciseMediaSource?) async {
        guard let source else {
            phase = .unavailable
            return
        }
        phase = .loading
        var request = URLRequest(
            url: source.url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 12
        )
        request.setValue("image/gif", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  Self.responseIsSuccessful(response),
                  data.count > 32,
                  data.count <= StrengthExerciseMediaPolicy.maximumDownloadBytes,
                  let dimensions = Self.gifDimensions(data),
                  StrengthExerciseMediaPolicy.accepts(
                      width: dimensions.width,
                      height: dimensions.height,
                      minimumPixels: source.minimumPixels
                  )
            else {
                phase = .failed
                return
            }
            phase = .loaded(data)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    private static func responseIsSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private static func gifDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.starts(with: [0x47, 0x49, 0x46]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }
        return (width.intValue, height.intValue)
    }
}

private struct StrengthNativeExerciseMediaView: View {
    let exercise: StrengthExerciseRow
    let exerciseID: String
    let source: StrengthExerciseMediaSource?
    let reduceMotion: Bool
    let minimized: Bool
    let showsTechniqueButton: Bool
    let showsSizeButton: Bool
    let onToggleSize: () -> Void

    @StateObject private var loader = StrengthExerciseMediaLoader()
    @State private var paused = false
    @State private var retry = 0
    @State private var showingGuide = false

    private var formGuide: StrengthExerciseFormGuide? {
        StrengthExerciseNativeAssets.guides[exerciseID]
    }

    var body: some View {
        GeometryReader { geometry in
            let controlRailWidth: CGFloat = showsSizeButton || showsTechniqueButton ? 46 : 40
            let dimension = max(
                0,
                min(
                    geometry.size.height - 12,
                    geometry.size.width - (controlRailWidth * 2) - 16
                )
            )

            ZStack {
                StrandPalette.surfaceInset

                ZStack {
                    Color.white
                    switch loader.phase {
                    case .unavailable:
                        fallbackContent
                    case .loading:
                        ProgressView()
                            .tint(StrandPalette.effortColor)
                            .controlSize(.small)
                    case let .loaded(data):
                        StrengthAnimatedGIFView(
                            data: data,
                            cacheKey: exerciseID,
                            paused: paused || reduceMotion
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !reduceMotion else { return }
                            paused.toggle()
                        }
                    case .failed:
                        fallbackContent
                    }
                }
                .frame(width: dimension, height: dimension)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false)
                }

                HStack {
                    VStack {
                        Spacer()
                        if showsSizeButton {
                            mediaControl(
                                systemName: minimized
                                    ? "arrow.up.left.and.arrow.down.right"
                                    : "arrow.down.right.and.arrow.up.left",
                                label: minimized
                                    ? "Expand exercise guide"
                                    : "Minimize exercise guide",
                                action: onToggleSize
                            )
                        }
                    }
                    .frame(width: controlRailWidth)

                    Spacer(minLength: 0)

                    VStack {
                        if showsTechniqueButton {
                            mediaControl(
                                systemName: "info",
                                label: "How to perform this exercise"
                            ) {
                                showingGuide = true
                            }
                        }
                        Spacer()
                        if case .failed = loader.phase {
                            mediaControl(
                                systemName: "arrow.clockwise",
                                label: "Retry exercise guide"
                            ) {
                                retry += 1
                            }
                        }
                        if case .loaded = loader.phase {
                            mediaControl(
                                systemName: paused || reduceMotion
                                    ? "play.fill"
                                    : "pause.fill",
                                label: paused || reduceMotion
                                    ? "Play exercise guide"
                                    : "Pause exercise guide"
                            ) {
                                guard !reduceMotion else { return }
                                paused.toggle()
                            }
                        }
                    }
                    .frame(width: controlRailWidth)
                }
                .padding(7)
            }
        }
        .task(id: "\(source?.cacheKey ?? "unavailable")-\(retry)") {
            await loader.load(source: source)
        }
        .onChange(of: exerciseID) { _ in
            paused = reduceMotion
        }
        .sheet(isPresented: $showingGuide) {
            StrengthExerciseFormGuideView(exercise: exercise)
        }
    }

    private var fallbackContent: some View {
        VStack(spacing: 7) {
            Image(
                systemName: exercise.equipment == "bodyweight"
                    ? "figure.strengthtraining.traditional"
                    : "dumbbell.fill"
            )
            .font(.system(size: minimized ? 22 : 29, weight: .semibold))
            .foregroundStyle(StrandPalette.effortColor)
            Text(formGuide?.movement ?? "Move through a controlled, comfortable range.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(minimized ? 1 : 3)
                .padding(.horizontal, 8)
        }
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exercise form guide")
    }

    private func mediaControl(
        systemName: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceRaised, in: Circle())
                .overlay {
                    Circle()
                        .stroke(StrandPalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct StrengthExerciseFormGuideView: View {
    @Environment(\.dismiss) private var dismiss

    let exercise: StrengthExerciseRow

    var body: some View {
        NavigationStack {
            ScrollView {
                StrengthExerciseTechniqueView(exercise: exercise)
                .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(strengthExerciseName(exercise))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}

struct StrengthExerciseTechniqueView: View {
    let exercise: StrengthExerciseRow

    private var guide: StrengthExerciseFormGuide? {
        guard let variant = StrengthExerciseGuidance.guide(for: exercise).animationVariant else {
            return nil
        }
        return StrengthExerciseNativeAssets.guides[variant.rawValue]
    }

    var body: some View {
        VStack(spacing: 0) {
            guideSection(
                1,
                "Setup",
                guide?.setup
                    ?? "Choose a stable position and a load you can control."
            )
            Divider().foregroundStyle(StrandPalette.hairline)
            guideSection(
                2,
                "Movement",
                guide?.movement
                    ?? "Move smoothly through a comfortable, controlled range."
            )
            Divider().foregroundStyle(StrandPalette.hairline)
            guideSection(
                3,
                "Breathing",
                guide?.breathing
                    ?? "Breathe continuously without losing position."
            )
            Divider().foregroundStyle(StrandPalette.hairline)
            guideSection(
                4,
                "Tempo",
                guide?.tempo
                    ?? "Control both directions of every repetition."
            )
            Divider().foregroundStyle(StrandPalette.hairline)
            guideSection(
                5,
                "Safety",
                guide?.safety
                    ?? "Stop for sharp pain, dizziness, or loss of control."
            )
        }
    }

    private func guideSection(
        _ index: Int,
        _ title: LocalizedStringKey,
        _ body: String
    ) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Text(String(format: "%02d", index))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 30, height: 30)
                .background(
                    StrandPalette.effortColor.opacity(0.14),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(body)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }
}

struct StrengthExerciseThumbnailView: View {
    let exercise: StrengthExerciseRow

    var body: some View {
        Image(
            systemName: exercise.equipment == "bodyweight"
                ? "figure.core.training"
                : "dumbbell.fill"
        )
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(StrandPalette.effortColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.effortColor.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

#if os(iOS)
private final class StrengthGIFImageCache {
    static let shared = StrengthGIFImageCache()
    let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 2
        cache.totalCostLimit = 40 * 1_024 * 1_024
        return cache
    }()
}

private struct StrengthAnimatedGIFView: UIViewRepresentable {
    let data: Data
    let cacheKey: String
    let paused: Bool

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.backgroundColor = .white
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        context.coordinator.paused = paused
        if context.coordinator.cacheKey != cacheKey {
            context.coordinator.cacheKey = cacheKey
            context.coordinator.loadID = UUID()
            let loadID = context.coordinator.loadID
            let key = cacheKey as NSString
            imageView.stopAnimating()
            imageView.image = nil
            if let image = StrengthGIFImageCache.shared.images.object(forKey: key) {
                imageView.image = image
            } else {
                let coordinator = context.coordinator
                DispatchQueue.global(qos: .userInitiated).async {
                    let decoded = decodedAnimatedImage(from: data)
                    DispatchQueue.main.async {
                        guard coordinator.loadID == loadID,
                              coordinator.cacheKey == cacheKey,
                              let decoded
                        else { return }
                        StrengthGIFImageCache.shared.images.setObject(
                            decoded.image,
                            forKey: key,
                            cost: decoded.cost
                        )
                        imageView.image = decoded.image
                        if !coordinator.paused {
                            imageView.startAnimating()
                        }
                    }
                }
            }
        }
        paused ? imageView.stopAnimating() : imageView.startAnimating()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var cacheKey: String?
        var loadID = UUID()
        var paused = true
    }
}

private struct DecodedStrengthGIF {
    let image: UIImage
    let cost: Int
}

private func decodedAnimatedImage(from data: Data) -> DecodedStrengthGIF? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    let count = CGImageSourceGetCount(source)
    guard count > 0 else { return nil }
    var timedFrames: [(image: UIImage, duration: TimeInterval)] = []
    for index in 0..<count {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options as CFDictionary
        ) else {
            continue
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? NSNumber
        timedFrames.append(
            (
                UIImage(cgImage: image),
                max(0.04, (unclamped ?? clamped)?.doubleValue ?? 0.1)
            )
        )
    }
    guard !timedFrames.isEmpty else { return nil }

    // UIImage only accepts one duration for the whole animation. Preserve each GIF
    // frame's delay by repeating references on a 20 fps timeline instead of flattening
    // a 10 fps movement plus endpoint holds into a visibly choppy 4 fps sequence.
    let frameQuantum: TimeInterval = 0.05
    let playbackFrames = timedFrames.flatMap { frame -> [UIImage] in
        Array(
            repeating: frame.image,
            count: max(1, Int((frame.duration / frameQuantum).rounded()))
        )
    }
    let duration = TimeInterval(playbackFrames.count) * frameQuantum
    let image = playbackFrames.count == 1
        ? playbackFrames[0]
        : UIImage.animatedImage(with: playbackFrames, duration: duration)
    guard let image else { return nil }
    let frameCost = timedFrames.reduce(0) { partial, frame in
        partial + Int(
            frame.image.size.width
                * frame.image.size.height
                * frame.image.scale
                * frame.image.scale
                * 4
        )
    }
    return DecodedStrengthGIF(image: image, cost: frameCost)
}
#elseif os(macOS)
private final class StrengthGIFImageCache {
    static let shared = StrengthGIFImageCache()
    let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 12
        return cache
    }()
}

private struct StrengthAnimatedGIFView: NSViewRepresentable {
    let data: Data
    let cacheKey: String
    let paused: Bool

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        if context.coordinator.cacheKey != cacheKey {
            context.coordinator.cacheKey = cacheKey
            let key = cacheKey as NSString
            let image = StrengthGIFImageCache.shared.images.object(forKey: key)
                ?? NSImage(data: data)
            imageView.image = image
            if let image {
                StrengthGIFImageCache.shared.images.setObject(image, forKey: key)
            }
        }
        imageView.animates = !paused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var cacheKey: String?
    }
}
#endif

private func webConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    return configuration
}

enum StrengthBodyMapMode: String, CaseIterable, Identifiable {
    case load
    case recovery

    var id: String { rawValue }
}

struct StrengthBodyMapView: View {
    let statuses: [StrengthMuscleStatus]
    let mode: StrengthBodyMapMode
    let selectedMuscles: Set<String>
    let onSelect: (String) -> Void

    private var scores: [String: Double] {
        Dictionary(uniqueKeysWithValues: statuses.map { status in
            (
                status.muscle,
                mode == .load ? status.loadScore : status.residualLoadScore
            )
        })
    }

    var body: some View {
        StrengthBodyMapWebView(
            scores: scores,
            mode: mode,
            selectedMuscles: selectedMuscles,
            onSelect: onSelect
        )
        .frame(maxWidth: .infinity)
        .frame(height: 306)
        .accessibilityElement(children: .contain)
    }
}

private struct StrengthBodyMapWebConfiguration: Equatable {
    let scores: [String: Double]
    let mode: StrengthBodyMapMode
    let selectedMuscles: Set<String>

    var pageURL: URL? {
        strengthMotionResourceURL(
            forResource: "body-map",
            withExtension: "html"
        )
    }

    var readAccessURL: URL? {
        strengthMotionResourceURL(
            forResource: "body-map",
            withExtension: "html"
        )?.deletingLastPathComponent()
    }

    var updateJavaScript: String? {
        let normalizedScores: [String: Double] = scores.reduce(into: [:]) { result, entry in
            let (muscle, value) = entry
            guard value.isFinite else { return }
            result[muscle] = min(max(value, 0), 1)
        }
        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "selected": selectedMuscles.sorted(),
            "scores": normalizedScores,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return "window.noopBodyMapUpdate(\(json));"
    }
}

private func strengthMotionResourceURL(
    forResource name: String,
    withExtension extensionName: String,
    subdirectory nestedSubdirectory: String? = nil
) -> URL? {
    let subdirectory = ["StrengthMotion", nestedSubdirectory]
        .compactMap { $0 }
        .joined(separator: "/")
    return Bundle.main.url(
        forResource: name,
        withExtension: extensionName,
        subdirectory: subdirectory
    ) ?? Bundle.main.url(forResource: name, withExtension: extensionName)
}

private func strengthMediaDescriptor(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
}

#if os(iOS)
private struct StrengthBodyMapWebView: UIViewRepresentable {
    let scores: [String: Double]
    let mode: StrengthBodyMapMode
    let selectedMuscles: Set<String>
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: webConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "noop.strength.body-map"
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(
            .init(scores: scores, mode: mode, selectedMuscles: selectedMuscles),
            in: webView
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onSelect: (String) -> Void
        private var pendingConfiguration: StrengthBodyMapWebConfiguration?
        private var appliedConfiguration: StrengthBodyMapWebConfiguration?
        private var applyingConfiguration: StrengthBodyMapWebConfiguration?
        private var pageIsLoading = false
        private var pageIsReady = false

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func update(_ configuration: StrengthBodyMapWebConfiguration, in webView: WKWebView) {
            pendingConfiguration = configuration
            if pageIsReady {
                applyPendingConfiguration(in: webView)
                return
            }
            guard !pageIsLoading,
                  let pageURL = configuration.pageURL,
                  let readAccessURL = configuration.readAccessURL
            else {
                return
            }
            pageIsLoading = true
            webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            pageIsLoading = false
            pageIsReady = true
            applyPendingConfiguration(in: webView)
        }

        private func applyPendingConfiguration(in webView: WKWebView) {
            guard applyingConfiguration == nil,
                  let configuration = pendingConfiguration,
                  configuration != appliedConfiguration,
                  let javaScript = configuration.updateJavaScript
            else {
                return
            }
            applyingConfiguration = configuration
            webView.evaluateJavaScript(javaScript) { [weak self, weak webView] _, error in
                guard let self else { return }
                self.applyingConfiguration = nil
                guard error == nil else {
                    self.pageIsReady = false
                    return
                }
                self.appliedConfiguration = configuration
                if let webView {
                    self.applyPendingConfiguration(in: webView)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.isFileURL { return .allow }
            guard url.scheme == "noop-body-map",
                  url.host == "select",
                  let muscle = url.pathComponents.dropFirst().first,
                  !muscle.isEmpty
            else {
                return .cancel
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSelect(muscle)
            }
            return .cancel
        }
    }
}
#elseif os(macOS)
private struct StrengthBodyMapWebView: NSViewRepresentable {
    let scores: [String: Double]
    let mode: StrengthBodyMapMode
    let selectedMuscles: Set<String>
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: webConfiguration())
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(
            .init(scores: scores, mode: mode, selectedMuscles: selectedMuscles),
            in: webView
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onSelect: (String) -> Void
        private var pendingConfiguration: StrengthBodyMapWebConfiguration?
        private var appliedConfiguration: StrengthBodyMapWebConfiguration?
        private var applyingConfiguration: StrengthBodyMapWebConfiguration?
        private var pageIsLoading = false
        private var pageIsReady = false

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func update(_ configuration: StrengthBodyMapWebConfiguration, in webView: WKWebView) {
            pendingConfiguration = configuration
            if pageIsReady {
                applyPendingConfiguration(in: webView)
                return
            }
            guard !pageIsLoading,
                  let pageURL = configuration.pageURL,
                  let readAccessURL = configuration.readAccessURL
            else {
                return
            }
            pageIsLoading = true
            webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            pageIsLoading = false
            pageIsReady = true
            applyPendingConfiguration(in: webView)
        }

        private func applyPendingConfiguration(in webView: WKWebView) {
            guard applyingConfiguration == nil,
                  let configuration = pendingConfiguration,
                  configuration != appliedConfiguration,
                  let javaScript = configuration.updateJavaScript
            else {
                return
            }
            applyingConfiguration = configuration
            webView.evaluateJavaScript(javaScript) { [weak self, weak webView] _, error in
                guard let self else { return }
                self.applyingConfiguration = nil
                guard error == nil else {
                    self.pageIsReady = false
                    return
                }
                self.appliedConfiguration = configuration
                if let webView {
                    self.applyPendingConfiguration(in: webView)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.isFileURL { return .allow }
            guard url.scheme == "noop-body-map",
                  url.host == "select",
                  let muscle = url.pathComponents.dropFirst().first,
                  !muscle.isEmpty
            else {
                return .cancel
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSelect(muscle)
            }
            return .cancel
        }
    }
}
#endif
