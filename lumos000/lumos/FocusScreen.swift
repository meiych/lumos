import SwiftUI
import Combine

struct FocusScreen: View {
    enum Mode {
        case idle
        case running
        case paused
    }

    enum Phase {
        case countdown
        case forward
    }

    @ObservedObject var store: LumosStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    let taskId: UUID?
    let close: () -> Void

    @State private var mode: Mode = .idle
    @State private var phase: Phase = .countdown
    @State private var countdownRemaining = 180
    @State private var forwardElapsed = 0

    @State private var focusStart: Date?
    @State private var currentSegmentStart: Date?
    @State private var segments: [(Date, Date)] = []
    @State private var pausedAt: Date?
    @State private var backgroundEnteredAt: Date?
    @State private var hadPause = false
    @State private var titleText: String = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFieldFocused: Bool

    private let cycleSeconds = 180
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let timerTapSize: CGFloat = 300
    private let defaultFocusTitle = "your life shard"
    private let shortPauseMergeSeconds: TimeInterval = 5 * 60
    private let autoEndPauseSeconds: TimeInterval = 30 * 60
    private let backgroundRunningGraceSeconds: TimeInterval = 5 * 60
    private let textGradientColors: [Color] = [
        Color(red: 0.99, green: 0.80, blue: 0.70),
        Color(red: 0.97, green: 0.60, blue: 0.82),
        Color(red: 0.66, green: 0.78, blue: 0.96),
        Color(red: 0.53, green: 0.86, blue: 0.93)
    ]

    private var focusTextGradient: LinearGradient {
        LinearGradient(
            colors: textGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var canvasColor: Color { colorScheme == .dark ? .black : .white }
    private var inkColor: Color { colorScheme == .dark ? .white : .black }
    private var timerShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.30)
    }
    private var titleEditColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
    }

    var body: some View {
        ZStack {
            canvasColor
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle {
                        commitTitleEdit()
                    }
                }

            GeometryReader { proxy in
                let size = proxy.size
                let safeTop = proxy.safeAreaInsets.top
                let safeBottom = proxy.safeAreaInsets.bottom
                let timerY = max(safeTop + 248, size.height * 0.52)
                let topAnchorY = safeTop + 6
                let bottomAnchorY = size.height - safeBottom - 22
                let titleY = (topAnchorY + timerY) * 0.5
                let quoteY = (timerY + bottomAnchorY) * 0.5

                Group {
                    if isEditingTitle {
                        TextField(defaultFocusTitle, text: $titleText)
                            .font(.custom("PingFangSC-Regular", size: 38))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .tint(inkColor)
                            .foregroundStyle(titleEditColor)
                            .focused($isTitleFieldFocused)
                            .onSubmit {
                                commitTitleEdit()
                            }
                    } else {
                        Text(displayFocusTaskTitle)
                            .font(.custom("PingFangSC-Regular", size: 38))
                            .foregroundStyle(focusTextGradient)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .onTapGesture {
                                isEditingTitle = true
                                DispatchQueue.main.async {
                                    isTitleFieldFocused = true
                                }
                            }
                    }
                }
                .frame(width: min(size.width - 56, 460))
                .position(x: size.width * 0.5, y: titleY)

                ZStack {
                    Text(timeText)
                        .font(.system(size: 94, weight: .regular, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(focusTextGradient)
                        .shadow(color: timerShadowColor, radius: 6, x: 0, y: 2)
                        .contentTransition(.identity)
                        .transaction { tx in
                            tx.animation = nil
                        }
                }
                .frame(width: timerTapSize, height: timerTapSize)
                .contentShape(Rectangle())
                .position(x: size.width * 0.5, y: timerY)
                .onTapGesture {
                    if isEditingTitle {
                        commitTitleEdit()
                        return
                    }
                    tapTimer()
                }
                .onLongPressGesture(minimumDuration: 0.8) {
                    commitTitleEdit()
                    endFocus()
                }

                Text("人最大的清醒，\n是知道自己在做什么，\n为什么做。")
                    .font(.custom("PingFangSC-Regular", size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusTextGradient)
                    .lineSpacing(8)
                    .tracking(0.2)
                    .frame(width: min(size.width - 88, 420))
                    .position(x: size.width * 0.5, y: quoteY)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { _ in
                    endFocus()
                }
        )
        .onReceive(ticker) { _ in
            tick()
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .onAppear {
            if let taskId, let item = store.task(with: taskId) {
                titleText = item.title
            } else {
                titleText = ""
            }
        }
        .onChange(of: isTitleFieldFocused) { _, focused in
            if !focused, isEditingTitle {
                commitTitleEdit()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                handleEnterBackground(at: Date())
            case .active:
                handleReturnForeground(at: Date())
            @unknown default:
                break
            }
        }
    }

    private var timeText: String {
        switch phase {
        case .countdown:
            return format(seconds: countdownRemaining)
        case .forward:
            return format(seconds: forwardElapsed)
        }
    }

    private var focusTaskTitle: String {
        guard let taskId else { return titleText.trimmingCharacters(in: .whitespacesAndNewlines) }
        return store.task(with: taskId)?.title ?? titleText
    }

    private var displayFocusTaskTitle: String {
        let title = focusTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? defaultFocusTitle : title
    }

    private func commitTitleEdit() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        titleText = trimmed
        isEditingTitle = false
        isTitleFieldFocused = false
        if let taskId {
            store.renameTask(taskId, title: trimmed)
        }
    }

    private func tapTimer() {
        switch mode {
        case .idle:
            startFocus()
        case .running:
            pauseFocus()
        case .paused:
            resumeFocus()
        }
    }

    private func startFocus() {
        let now = Date()
        focusStart = now
        currentSegmentStart = now
        mode = .running
        phase = .countdown
        countdownRemaining = cycleSeconds
        forwardElapsed = 0
        segments.removeAll()
        pausedAt = nil
        backgroundEnteredAt = nil
        hadPause = false
    }

    private func pauseFocus() {
        guard mode == .running else { return }
        let now = Date()
        closeCurrentSegment(at: now)
        currentSegmentStart = nil
        pausedAt = now
        backgroundEnteredAt = nil
        hadPause = true
        mode = .paused
    }

    private func resumeFocus() {
        guard mode == .paused else { return }
        let now = Date()
        guard !autoEndIfPauseExpired(now: now) else { return }

        if shouldMergePause(at: now),
           let last = segments.popLast() {
            currentSegmentStart = last.0
        } else {
            currentSegmentStart = now
        }
        pausedAt = nil
        backgroundEnteredAt = nil
        mode = .running
    }

    private func endFocus() {
        commitTitleEdit()
        guard mode != .idle else {
            close()
            return
        }

        if mode == .running, currentSegmentStart != nil {
            closeCurrentSegment(at: Date())
        }
        currentSegmentStart = nil
        pausedAt = nil
        backgroundEnteredAt = nil
        mode = .idle

        persistFocus()
        close()
    }

    private func persistFocus() {
        guard let firstStart = focusStart else { return }
        let end = Date()
        let persistedSegments: [(Date, Date)] = segments.isEmpty ? [(firstStart, end)] : segments

        for segment in persistedSegments {
            guard segment.1 > segment.0 else { continue }
            store.addFocusSession(
                FocusSession.make(
                    taskId: taskId,
                    startAt: segment.0,
                    endAt: segment.1,
                    hadPause: hadPause
                ),
                fallbackTitle: titleText
            )
        }
    }

    private func tick() {
        switch mode {
        case .running:
            advanceDisplay(by: 1)
        case .paused:
            _ = autoEndIfPauseExpired(now: Date())
        case .idle:
            break
        }
    }

    private func handleEnterBackground(at now: Date) {
        guard mode == .running || mode == .paused else { return }
        if backgroundEnteredAt == nil {
            backgroundEnteredAt = now
        }
    }

    private func handleReturnForeground(at now: Date) {
        defer { backgroundEnteredAt = nil }
        guard let enteredAt = backgroundEnteredAt else {
            if mode == .paused {
                _ = autoEndIfPauseExpired(now: now)
            }
            return
        }

        guard now > enteredAt else {
            if mode == .paused {
                _ = autoEndIfPauseExpired(now: now)
            }
            return
        }

        switch mode {
        case .running:
            let backgroundElapsed = now.timeIntervalSince(enteredAt)
            if backgroundElapsed <= backgroundRunningGraceSeconds {
                advanceDisplay(by: Int(backgroundElapsed.rounded(.down)))
                return
            }

            let autoPausedAt = enteredAt.addingTimeInterval(backgroundRunningGraceSeconds)
            closeCurrentSegment(at: autoPausedAt)
            hadPause = true
            mode = .paused
            pausedAt = autoPausedAt
            advanceDisplay(by: Int(backgroundRunningGraceSeconds.rounded(.down)))
            _ = autoEndIfPauseExpired(now: now)
        case .paused:
            _ = autoEndIfPauseExpired(now: now)
        case .idle:
            break
        }
    }

    private func closeCurrentSegment(at end: Date) {
        guard let start = currentSegmentStart else { return }
        guard end > start else { return }
        segments.append((start, end))
    }

    private func shouldMergePause(at now: Date) -> Bool {
        guard let pausedAt else { return false }
        return now.timeIntervalSince(pausedAt) <= shortPauseMergeSeconds
    }

    @discardableResult
    private func autoEndIfPauseExpired(now: Date) -> Bool {
        guard mode == .paused, let pausedAt else { return false }
        guard now.timeIntervalSince(pausedAt) >= autoEndPauseSeconds else { return false }
        endFocus()
        return true
    }

    private func advanceDisplay(by seconds: Int) {
        guard seconds > 0 else { return }
        switch phase {
        case .countdown:
            if seconds < countdownRemaining {
                countdownRemaining -= seconds
                return
            }

            let overflow = seconds - countdownRemaining
            countdownRemaining = 0
            phase = .forward
            forwardElapsed += overflow
        case .forward:
            forwardElapsed += seconds
        }
    }

    private func format(seconds: Int) -> String {
        let safe = max(0, seconds)
        let m = safe / 60
        let s = safe % 60
        return String(format: "%02d:%02d", m, s)
    }
}

#if false
#Preview {
    FocusScreen(store: LumosStore(), taskId: nil, close: {})
}
#endif
