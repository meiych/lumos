import SwiftUI
import UIKit
import Combine
import CoreMotion

struct TimelineScreen: View {
    private static let focusPreviewAnchorDefaultsKey = "timeline.focusPreviewAnchorDayStartEpoch"

    private enum TopMaskMode {
        case hidden
        case initialFullWidth
        case tuned
    }

    // Switch here for quick A/B comparison.
    private let topMaskMode: TopMaskMode = .tuned

    @ObservedObject var store: LumosStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let openTaskDetailAt: (Date) -> Void
    let openTaskDetailForTask: (UUID) -> Void
    let openFocus: () -> Void

    private let baseHourHeight: CGFloat = 120
    private let timelineFontSize: CGFloat = 15
    private let axisX: CGFloat = 88
    private let axisStrokeWidth: CGFloat = 3
    private let taskGlyphWidth: CGFloat = 20
    private let pointTapTargetWidth: CGFloat = 62
    private let pointTapTargetHeight: CGFloat = 42
    private let pointTapTargetLeftExpansion: CGFloat = 12
    private let lineTapTargetWidth: CGFloat = 72
    private let lineTapTargetVerticalPadding: CGFloat = 8
    private let lineTapTargetLeftExpansion: CGFloat = 12
    private let editLongPressMaxDistance: CGFloat = 48
    private let shortFocusPointThresholdSeconds: TimeInterval = 10 * 60
    private let minimumFocusDisplaySeconds: TimeInterval = 60
    private let axisCreationTapHalfWidth: CGFloat = 44
    private let hourLabelX: CGFloat = 56
    private let dateColumnLabelX: CGFloat = 20
    private let dateColumnLabelGapTighten: CGFloat = 24
    private let axisHourDisplayOffset = 0
    private let dateLabelAnchorHour: CGFloat = 12
    private let initialDaysPast = 6
    private let initialDaysFuture = 7
    private let weekChunkDays = 7
    private let deleteSwipeThreshold: CGFloat = 52
    private let boundaryPullTrigger: CGFloat = 88
    private let boundaryPullReset: CGFloat = 24
    private let lineSurfaceToggleDragThreshold: CGFloat = 26
    private let surfaceBackgroundRightInset: CGFloat = 20
    private var timelineGray: Color { Color(white: colorScheme == .dark ? 0.42 : 0.58) }
    private var canvasColor: Color { colorScheme == .dark ? .black : .white }
    private var inkColor: Color { colorScheme == .dark ? .white : .black }
    private var editPulseTargetColor: Color { colorScheme == .dark ? .black : .white }
    private var primaryTitleColor: Color { inkColor }
    private var secondaryTitleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.68)
    }
    private var surfaceFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.gray.opacity(0.18)
    }
    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd   EEEE"
        return formatter
    }()

    @State private var didInitialScroll = false
    @State private var editingTaskID: UUID?
    @State private var editingTitleTaskID: UUID?
    @State private var editingTitleText: String = ""
    @State private var dragOrigins: [UUID: (Date, Date?)] = [:]
    @State private var endpointDragAnchors: [UUID: (start: Date, end: Date)] = [:]
    @State private var draftQuickCreate: DraftQuickCreate?
    @FocusState private var isDraftInputFocused: Bool
    @FocusState private var isTitleInputFocused: Bool
    @State private var nowAnchorYInViewport: CGFloat = .nan
    @State private var scrollContentGlobalMinY: CGFloat = .nan
    @State private var smoothedContentMinY: CGFloat = .nan
    @State private var viewportGlobalMinYState: CGFloat = 0
    @State private var nowTime: Date = Date()
    @State private var viewportWidth: CGFloat = 0
    @State private var initialAlignAttempts: Int = 0
    @State private var isInitialNowAnchorStabilizationActive = false
    @State private var lastLifecycleAlignAt: Date = .distantPast
    @State private var isCommittingDraftPoint = false
    @State private var suppressTapUntil: Date = .distantPast
    @State private var loadedDaysPast: Int = 6
    @State private var loadedDaysFuture: Int = 7
    @State private var isExpandingPast = false
    @State private var isExpandingFuture = false
    @State private var editPulseOn = false
    @State private var canExpandPast = true
    @State private var canExpandFuture = true
    @State private var pastBoundaryPrimed = false
    @State private var futureBoundaryPrimed = false
    @State private var focusDisturbanceBase: CGFloat = 0
    @State private var focusDisturbanceUpdatedAt: Date = .distantPast
    @State private var focusFlowXBase: CGFloat = 0
    @State private var focusFlowYBase: CGFloat = 0
    @State private var draftFocusRequestID: Int = 0
    @State private var focusPreviewAnchorDayStart: Date = {
        let key = TimelineScreen.focusPreviewAnchorDefaultsKey
        let savedEpoch = UserDefaults.standard.double(forKey: key)
        if savedEpoch > 0 {
            return Date(timeIntervalSince1970: savedEpoch)
        }
        let todayStart = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(todayStart.timeIntervalSince1970, forKey: key)
        return todayStart
    }()
    @State private var lastScrollSampleY: CGFloat = .nan
    @State private var lastScrollSampleAt: Date = .distantPast
    @StateObject private var shakeDetector = ShakeDetector()

    private let nowTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canCreateOnTimeline: Bool { FeatureFlags.timelineCreateEnabled }
    private var canEditOnTimeline: Bool { FeatureFlags.timelineEditEnabled }
    private var canCompleteOnTimeline: Bool { FeatureFlags.timelineCompleteEnabled }
    // Keep preview always visible during this visual tuning phase.
    private var canShowFocusGlowPreview: Bool { true }
    private var isPointEditingMode: Bool {
        guard let taskID = editingTaskID, let task = store.task(with: taskID) else { return false }
        return canEditOnTimeline && task.type == .point
    }
    private var timelineSnapMinutes: Int { 10 }
    private var totalDays: Int { loadedDaysPast + loadedDaysFuture + 1 }
    // Keep hour spacing fixed regardless of typography tweaks.
    private var hourHeight: CGFloat { baseHourHeight }
    private var pointTaskHeight: CGFloat { hourHeight / 6 }
    private var taskBlockCornerRadius: CGFloat { min(taskGlyphWidth, pointTaskHeight) * 0.46 }
    private var dayHeight: CGFloat { hourHeight * 24 }
    private var totalHeight: CGFloat { CGFloat(totalDays) * dayHeight }
    private var taskGlyphX: CGFloat { axisX + (axisStrokeWidth - taskGlyphWidth) / 2 }
    private var taskTitleX: CGFloat { axisX + (axisX - hourLabelX) }
    // Place the surface block's left edge between hour labels and day/date labels.
    private var surfaceBackgroundX: CGFloat { max(16, (hourLabelX + dateColumnLabelX) * 0.5) }
    private var surfaceBackgroundWidth: CGFloat { max(220, viewportWidth - surfaceBackgroundX - surfaceBackgroundRightInset) }

    private var startDay: Date {
        let today = Calendar.current.startOfDay(for: nowTime)
        return Calendar.current.date(byAdding: .day, value: -loadedDaysPast, to: today) ?? today
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    let viewportGlobalMinY = viewport.frame(in: .global).minY
                    let viewportGlobalMaxY = viewportGlobalMinY + viewport.size.height
                    let fullColumnHeight = viewport.size.height + viewport.safeAreaInsets.top + viewport.safeAreaInsets.bottom
                    let fullColumnMinY = viewportGlobalMinY - viewport.safeAreaInsets.top
                    let isViewportReadyForAlignment = viewport.size.height > 1
                    let desiredNowYInViewport = isViewportReadyForAlignment
                        ? (viewport.size.height * 0.5 - viewport.safeAreaInsets.top * 0.85)
                        : (viewport.size.height * 0.5)
                    let nowAnchorUnitY = isViewportReadyForAlignment
                        ? min(max(desiredNowYInViewport / max(viewport.size.height, 1), 0), 1)
                        : 0.5

                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            scrollOffsetTracker
                            interactionLayer
                            axisLayer
                            surfaceLayer
                            taskLayer
                            draftLayer
                            nowAnchor
                            pagingSentinels
                        }
                        .frame(height: totalHeight)
                    }
                    .scrollDismissesKeyboard(.never)
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { _ in
                                handleGlobalRecenterDoubleTap(
                                    proxy: proxy,
                                    nowAnchorUnitY: nowAnchorUnitY
                                )
                            },
                        including: .all
                    )
                    .scrollDisabled(
                        draftQuickCreate != nil ||
                        editingTitleTaskID != nil ||
                        isCommittingDraftPoint
                    )
                    .coordinateSpace(name: "timeline-scroll")
                    .background(canvasColor)
                    .onAppear {
                        shakeDetector.start()
                        viewportGlobalMinYState = viewportGlobalMinY
                        viewportWidth = viewport.size.width
                        // Wait for a valid viewport before seeding and aligning.
                        if isViewportReadyForAlignment {
                            nowAnchorYInViewport = desiredNowYInViewport
                            lastLifecycleAlignAt = Date()
                        } else {
                            nowAnchorYInViewport = .nan
                        }

                        // Re-arm alignment each time the screen appears.
                        initialAlignAttempts = 0
                        isInitialNowAnchorStabilizationActive = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                            isInitialNowAnchorStabilizationActive = false
                        }

                        if !didInitialScroll {
                            didInitialScroll = true
                            loadedDaysPast = initialDaysPast
                            loadedDaysFuture = initialDaysFuture
                            isExpandingPast = false
                            isExpandingFuture = false
                            canExpandPast = true
                            canExpandFuture = true
                            pastBoundaryPrimed = false
                            futureBoundaryPrimed = false
                        }

                        guard isViewportReadyForAlignment else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            proxy.scrollTo("now-anchor", anchor: UnitPoint(x: 0.5, y: nowAnchorUnitY))
                        }
                    }
                    .onDisappear {
                        shakeDetector.stop()
                        isInitialNowAnchorStabilizationActive = false
                        isCommittingDraftPoint = false
                        pastBoundaryPrimed = false
                        futureBoundaryPrimed = false
                    }
                    .onReceive(shakeDetector.$shakeToken.compactMap { $0 }) { _ in
                        guard editingTaskID == nil, editingTitleTaskID == nil, draftQuickCreate == nil else { return }
                        commitDraftPoint()
                        commitTitleEdit()
                        editingTaskID = nil
                        openFocus()
                    }
                    .onPreferenceChange(NowAnchorYPreferenceKey.self) { y in
                        if y.isFinite {
                            nowAnchorYInViewport = y - viewportGlobalMinY
                            // First-open stabilization: force the anchor onto the configured target line.
                            if didInitialScroll, isInitialNowAnchorStabilizationActive {
                                let delta = abs((y - viewportGlobalMinY) - desiredNowYInViewport)
                                if delta <= 1.5 {
                                    isInitialNowAnchorStabilizationActive = false
                                } else if initialAlignAttempts < 3 {
                                    initialAlignAttempts += 1
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                        guard isInitialNowAnchorStabilizationActive else { return }
                                        proxy.scrollTo("now-anchor", anchor: UnitPoint(x: 0.5, y: nowAnchorUnitY))
                                    }
                                } else {
                                    isInitialNowAnchorStabilizationActive = false
                                }
                            }
                        } else {
                            nowAnchorYInViewport = .nan
                        }
                    }
                    .onPreferenceChange(ScrollContentGlobalMinYPreferenceKey.self) { y in
                        guard y.isFinite else { return }
                        scrollContentGlobalMinY = y
                        registerFocusDisturbanceSample(at: y)
                        if !smoothedContentMinY.isFinite {
                            smoothedContentMinY = y
                        } else {
                            // Low-pass filter to reduce jitter in date-column motion.
                            smoothedContentMinY = smoothedContentMinY * 0.72 + y * 0.28
                        }
                    }
                    .onPreferenceChange(TopSentinelGlobalYPreferenceKey.self) { y in
                        maybeExpandPastIfNeeded(
                            topSentinelGlobalY: y,
                            viewportGlobalMinY: viewportGlobalMinY
                        )
                    }
                    .onPreferenceChange(BottomSentinelGlobalYPreferenceKey.self) { y in
                        maybeExpandFutureIfNeeded(
                            bottomSentinelGlobalY: y,
                            viewportGlobalMaxY: viewportGlobalMaxY
                        )
                    }
                    .onReceive(nowTicker) { value in
                        nowTime = value
                    }
                    .onChange(of: editingTaskID) { _, newValue in
                        if newValue != nil {
                            restartEditPulseAnimation()
                        } else {
                            focusDisturbanceBase = 0
                            focusDisturbanceUpdatedAt = .distantPast
                            focusFlowXBase = 0
                            focusFlowYBase = 0
                            withAnimation(.easeOut(duration: 0.18)) {
                                editPulseOn = false
                            }
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            nowTime = Date()
                            // Keep user's current scroll position when returning from background.
                            // Re-centering is only for cold launch (handled by onAppear + size-ready path).
                        }
                    }
                    .onChange(of: viewport.size.width) { _, newWidth in
                        viewportWidth = newWidth
                    }
                    .onChange(of: viewport.size.height) { _, newHeight in
                        guard newHeight > 1 else { return }
                        // First frame can report height 0, which previously centered at y=0.
                        // Re-center once real size arrives.
                        let delta = abs(nowAnchorYInViewport - desiredNowYInViewport)
                        guard !nowAnchorYInViewport.isFinite || delta > 6 else { return }
                        lastLifecycleAlignAt = Date()
                        initialAlignAttempts = 0
                        isInitialNowAnchorStabilizationActive = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                            proxy.scrollTo("now-anchor", anchor: UnitPoint(x: 0.5, y: nowAnchorUnitY))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                            isInitialNowAnchorStabilizationActive = false
                        }
                    }
                    .onChange(of: viewportGlobalMinY) { _, newValue in
                        viewportGlobalMinYState = newValue
                    }
                    movingDateColumn(
                        viewportHeight: fullColumnHeight,
                        viewportGlobalMinY: fullColumnMinY,
                        safeTopInset: viewport.safeAreaInsets.top,
                        safeBottomInset: viewport.safeAreaInsets.bottom
                    )
                        .offset(y: -viewport.safeAreaInsets.top)
                        .zIndex(2)

                }
                .mask(
                    activeTopFadeMask(
                        viewportWidth: viewport.size.width,
                        viewportHeight: viewport.size.height + viewport.safeAreaInsets.top + viewport.safeAreaInsets.bottom
                    )
                    .offset(y: -viewport.safeAreaInsets.top)
                )
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var nowAnchor: some View {
        let nowY = max(0, min(totalHeight - 1, yPosition(for: nowTime)))

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: nowY)
            Color.clear
                .frame(width: max(viewportWidth, 1), height: 1)
                .id("now-anchor")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: NowAnchorYPreferenceKey.self,
                            value: geo.frame(in: .global).midY
                        )
                    }
                )
            Color.clear
                .frame(height: max(0, totalHeight - nowY - 1))
        }
        .frame(width: max(viewportWidth, 1), height: totalHeight, alignment: .topLeading)
    }

    private var scrollOffsetTracker: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollContentGlobalMinYPreferenceKey.self,
                        value: geo.frame(in: .global).minY
                    )
                }
            )
            .offset(x: 0, y: 0)
    }


private var pagingSentinels: some View {
    ZStack(alignment: .topLeading) {
        Color.clear
            .frame(width: 1, height: 1)
            .offset(x: 0, y: 0)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TopSentinelGlobalYPreferenceKey.self,
                        value: geo.frame(in: .global).minY
                    )
                }
            )

        Color.clear
            .frame(width: 1, height: 1)
            .offset(x: 0, y: max(0, totalHeight - 2))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: BottomSentinelGlobalYPreferenceKey.self,
                        value: geo.frame(in: .global).minY
                    )
                }
            )
    }
}

private var axisLayer: some View {
    ZStack(alignment: .topLeading) {
        let nowY = max(0, min(totalHeight, yPosition(for: nowTime)))
        let pastColor = timelineGray
        let futureColor = inkColor

        Rectangle()
            .fill(pastColor)
            .frame(width: axisStrokeWidth, height: nowY)
            .offset(x: axisX)

        Rectangle()
            .fill(futureColor)
            .frame(width: axisStrokeWidth, height: max(0, totalHeight - nowY))
            .offset(x: axisX, y: nowY)

        Rectangle()
            .fill(futureColor)
            .frame(width: axisStrokeWidth, height: 1)
            .offset(x: axisX, y: nowY)

        ForEach(0..<totalDays, id: \.self) { day in
            let dayDate = dateForDay(day)
            let dayY = yPosition(for: dayDate)

            ForEach(0..<24, id: \.self) { hour in
                let hourTickY = dayY + CGFloat(hour) * hourHeight
                // Keep hour text center aligned with each hour tick.
                let labelY = pixelAligned(hourTickY)
                let isPast = hourTickY <= nowY
                let tickColor = isPast ? pastColor : futureColor
                let displayHour = (hour + axisHourDisplayOffset) % 24

                Text("\(displayHour)")
                    .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(tickColor)
                    .opacity(1.0)
                    .position(x: hourLabelX, y: labelY)
            }
        }
    }
}

    private var interactionLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { tap in
                            guard Date() >= suppressTapUntil else { return }
                            if !canEditOnTimeline {
                                editingTaskID = nil
                            }
                            if editingTitleTaskID != nil {
                                commitTitleEdit()
                                resetRecenterTapState()
                                return
                            }
                            if draftQuickCreate != nil {
                                commitDraftPoint()
                                return
                            }
                            handleTap(
                                at: tap.location,
                                viewportY: viewportY(from: tap.location, in: geo)
                            )
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: editLongPressMaxDistance)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { sequence in
                            guard Date() >= suppressTapUntil else { return }
                            guard !isCommittingDraftPoint else { return }
                            switch sequence {
                            case .second(true, let drag?):
                                let viewportY = viewportY(from: drag.location, in: geo)
                                handleSurfaceLongPress(at: drag.location, viewportY: viewportY)
                            default:
                                break
                            }
                        }
                )
    }
}

    private var draftLayer: some View {
        Group {
            if let draft = draftQuickCreate {
                let y = yPosition(for: draft.date)
                let pointHeight = pointTaskHeight
                let pointTopY = y - pointHeight * 0.5
                let pointCornerRadius = min(taskBlockCornerRadius, pointHeight * 0.5)
                let titleTopY = y - 10
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: pointCornerRadius, style: .continuous)
                        .fill(inkColor)
                        .frame(width: taskGlyphWidth, height: pointHeight)
                        .offset(x: taskGlyphX, y: pointTopY)
                        .shadow(color: inkColor.opacity(0.16), radius: 1.2, x: 0, y: 0)
                        .allowsHitTesting(false)

                    TextField("", text: draftTitleBinding)
                        .focused($isDraftInputFocused)
                        .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                        .foregroundStyle(inkColor)
                        .tint(inkColor)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .onAppear {
                            requestDraftInputFocus()
                        }
                        .onSubmit {
                            commitDraftPoint(suppressFollowupTap: true)
                        }
                        .id("draft-input")
                        .frame(width: 220, alignment: .leading)
                        .frame(height: 20, alignment: .leading)
                        .offset(x: taskTitleX, y: titleTopY)
                        .onTapGesture { }
                }
            }
        }
    }

    private var surfaceLayer: some View {
        ForEach(store.tasks.filter { $0.type == .surface }) { task in
            let startY = yPosition(for: task.startAt)
            let endY = yPosition(for: task.endAt ?? task.startAt.addingTimeInterval(3600))
            let height = max(46, endY - startY)
            let surfaceTitleInset: CGFloat = 12
            let titleHeight: CGFloat = 20
            let titleWidth = max(120, surfaceBackgroundWidth - surfaceTitleInset * 2)
            // Surface title row anchors to the 10-minute tick below the top edge.
            let surfaceTitleTargetY = startY + pointTaskHeight
            let titleTopY = surfaceTitleTargetY - titleHeight * 0.5
            let surfaceTextColor = surfaceTitleColor(titleTopY: titleTopY)
            let isEditingSurface = canEditOnTimeline && editingTaskID == task.id
            let interactiveX = max(surfaceBackgroundX, axisX + 16)
            let interactiveWidth = max(0, surfaceBackgroundWidth - (interactiveX - surfaceBackgroundX))
            // Reserve the axis creation corridor so surface long-press won't block point creation.
            let longPressCaptureX = max(interactiveX, axisX + axisCreationTapHalfWidth + 4)
            let longPressCaptureWidth = max(0, surfaceBackgroundWidth - (longPressCaptureX - surfaceBackgroundX))
            // Keep surface background transparent to scroll/tap in normal mode.
            // Only enable interaction when this exact surface is already in edit mode.
            let backgroundHitEnabled = editingTitleTaskID == nil && isEditingSurface

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(surfaceFillColor)
                    .frame(width: surfaceBackgroundWidth, height: height)
                    .offset(x: surfaceBackgroundX, y: startY)
                    .overlay {
                        if isEditingSurface {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(editPulseTargetColor.opacity(editPulseOn ? 0.52 : 0.0))
                                .frame(width: surfaceBackgroundWidth, height: height)
                                .offset(x: surfaceBackgroundX, y: startY)
                        }
                    }
                    .allowsHitTesting(false)

                if interactiveWidth > 1 {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: interactiveWidth, height: height)
                        .offset(x: interactiveX, y: startY)
                        .allowsHitTesting(backgroundHitEnabled)
                        .onTapGesture {
                            guard canEditOnTimeline else { return }
                            if editingTaskID == task.id {
                                editingTaskID = nil
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    guard canEditOnTimeline, editingTaskID == task.id else { return }
                                    if dragOrigins[task.id] == nil {
                                        dragOrigins[task.id] = (task.startAt, task.endAt)
                                    }
                                    guard let base = dragOrigins[task.id] else { return }
                                    let delta = snappedMinutes(from: value.translation.height)
                                    let movedStart = Calendar.current.date(byAdding: .minute, value: delta, to: base.0) ?? base.0
                                    let baseEnd = base.1 ?? base.0.addingTimeInterval(3600)
                                    let movedEnd = Calendar.current.date(byAdding: .minute, value: delta, to: baseEnd) ?? baseEnd
                                    store.updateRangeTaskTime(
                                        task.id,
                                        startAt: movedStart,
                                        endAt: movedEnd,
                                        snapMinutes: timelineSnapMinutes,
                                        persist: false
                                    )
                                }
                                .onEnded { _ in
                                    let hadChanges = dragOrigins[task.id] != nil
                                    dragOrigins[task.id] = nil
                                    if hadChanges {
                                        store.saveAll()
                                    }
                                }
                        , including: (canEditOnTimeline && editingTaskID == task.id) ? .all : .none
                        )
                }

                if longPressCaptureWidth > 1 {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: longPressCaptureWidth, height: height)
                        .offset(x: longPressCaptureX, y: startY)
                        // Only capture long-press when no shape edit session is active.
                        // Otherwise taps should fall through to global interaction layer
                        // so line/point edit mode can be exited by tapping blank area.
                        .allowsHitTesting(
                            canEditOnTimeline &&
                            editingTitleTaskID == nil &&
                            editingTaskID == nil &&
                            !isEditingSurface
                        )
                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: editLongPressMaxDistance) {
                            activateTimelineEditMode(for: task.id)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            restartEditPulseAnimation()
                        }
                }

                if isEditingSurface {
                    let edgeHitThickness: CGFloat = 26
                    let rightEdgeHitWidth: CGFloat = 26
                    let renderedEndY = startY + height
                    let topEdgeHitY = startY - edgeHitThickness * 0.5
                    let bottomEdgeHitY = renderedEndY - edgeHitThickness * 0.5
                    let rightEdgeHitX = surfaceBackgroundX + surfaceBackgroundWidth - rightEdgeHitWidth * 0.5

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: surfaceBackgroundWidth, height: edgeHitThickness)
                        .offset(x: surfaceBackgroundX, y: topEdgeHitY)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard canEditOnTimeline, editingTaskID == task.id else { return }
                                    let step = TimeInterval(max(1, timelineSnapMinutes) * 60)
                                    let currentEnd = task.endAt ?? task.startAt.addingTimeInterval(step)
                                    if endpointDragAnchors[task.id] == nil {
                                        endpointDragAnchors[task.id] = (start: task.startAt, end: currentEnd)
                                    }
                                    guard let base = endpointDragAnchors[task.id] else { return }
                                    let delta = snappedMinutes(from: value.translation.height)
                                    let movedStart = Calendar.current.date(byAdding: .minute, value: delta, to: base.start) ?? base.start
                                    store.updateRangeTaskEndpoint(
                                        task.id,
                                        endpoint: .start,
                                        to: movedStart,
                                        snapMinutes: timelineSnapMinutes,
                                        persist: false
                                    )
                                }
                                .onEnded { _ in
                                    let hadChanges = endpointDragAnchors[task.id] != nil
                                    endpointDragAnchors[task.id] = nil
                                    if hadChanges {
                                        store.saveAll()
                                    }
                                }
                        )

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: surfaceBackgroundWidth, height: edgeHitThickness)
                        .offset(x: surfaceBackgroundX, y: bottomEdgeHitY)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard canEditOnTimeline, editingTaskID == task.id else { return }
                                    let step = TimeInterval(max(1, timelineSnapMinutes) * 60)
                                    let currentEnd = task.endAt ?? task.startAt.addingTimeInterval(step)
                                    if endpointDragAnchors[task.id] == nil {
                                        endpointDragAnchors[task.id] = (start: task.startAt, end: currentEnd)
                                    }
                                    guard let base = endpointDragAnchors[task.id] else { return }
                                    let delta = snappedMinutes(from: value.translation.height)
                                    let movedEnd = Calendar.current.date(byAdding: .minute, value: delta, to: base.end) ?? base.end
                                    store.updateRangeTaskEndpoint(
                                        task.id,
                                        endpoint: .end,
                                        to: movedEnd,
                                        snapMinutes: timelineSnapMinutes,
                                        persist: false
                                    )
                                }
                                .onEnded { _ in
                                    let hadChanges = endpointDragAnchors[task.id] != nil
                                    endpointDragAnchors[task.id] = nil
                                    if hadChanges {
                                        store.saveAll()
                                    }
                                }
                        )

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: rightEdgeHitWidth, height: height)
                        .offset(x: rightEdgeHitX, y: startY)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard canEditOnTimeline, editingTaskID == task.id else { return }
                                    if value.translation.width < -lineSurfaceToggleDragThreshold,
                                       abs(value.translation.width) > abs(value.translation.height) {
                                        dragOrigins[task.id] = nil
                                        endpointDragAnchors[task.id] = nil
                                        store.convertSurfaceToLine(task.id, snapMinutes: timelineSnapMinutes)
                                        restartEditPulseAnimation()
                                    }
                                }
                        )
                }

                Group {
                    if editingTitleTaskID == task.id {
                        titleEditField(color: surfaceTextColor)
                            .id("title-edit-\(task.id.uuidString)")
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .frame(width: titleWidth, alignment: .trailing)
                    } else if canEditOnTimeline {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Text(task.displayTitle)
                                .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                                .foregroundStyle(surfaceTextColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    beginTitleEdit(task)
                                }
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    commitDraftPoint()
                                    commitTitleEdit()
                                    openTaskDetailForTask(task.id)
                                }
                                .simultaneousGesture(deleteSwipeGesture(for: task.id))
                        }
                        .frame(width: titleWidth, alignment: .trailing)
                    } else {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Text(task.displayTitle)
                                .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                                .foregroundStyle(surfaceTextColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(width: titleWidth, alignment: .trailing)
                    }
                }
                .frame(width: titleWidth, height: titleHeight, alignment: .trailing)
                .offset(x: surfaceBackgroundX + surfaceTitleInset, y: titleTopY)
            }
            .allowsHitTesting(!isPointEditingMode)
        }
    }

    private var taskLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.tasks.filter { $0.type != .surface }) { task in
                switch task.type {
                case .point:
                    pointView(task)
                case .line:
                    lineView(task)
                case .surface:
                    EmptyView()
                }
            }

            if canShowFocusGlowPreview {
                focusPreviewOverlay
            }
        }
    }

    private var focusPreviewOverlay: some View {
        let previewLineHour = 7
        let previewPointHour = 6
        guard
            let lineStart = Calendar.current.date(
                bySettingHour: previewLineHour,
                minute: 0,
                second: 0,
                of: focusPreviewAnchorDayStart
            ),
            let lineEnd = Calendar.current.date(byAdding: .hour, value: 1, to: lineStart),
            let anchor = Calendar.current.date(
                bySettingHour: previewPointHour,
                minute: 0,
                second: 0,
                of: focusPreviewAnchorDayStart
            )
        else {
            return AnyView(EmptyView())
        }

        let lineStartY = yPosition(for: lineStart)
        let lineEndY = yPosition(for: lineEnd)
        let anchorY = yPosition(for: anchor)
        let endpointInset = pointTaskHeight * 0.5
        let renderedStartY = lineStartY - endpointInset
        let lineHeight = max(pointTaskHeight, lineEndY - lineStartY + pointTaskHeight)
        let lineCornerRadius = min(taskBlockCornerRadius, lineHeight * 0.5)
        let previewLine = TaskItem.makeLine(startAt: lineStart, endAt: lineEnd, title: "")

        return AnyView(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: lineCornerRadius, style: .continuous)
                    .fill(timelineGray)
                    .frame(width: taskGlyphWidth, height: lineHeight)
                    .offset(x: taskGlyphX, y: renderedStartY)
                    .allowsHitTesting(false)
                focusLineOverlay(
                    task: previewLine,
                    endDate: lineEnd,
                    height: lineHeight,
                    startY: renderedStartY,
                    segments: [(lineStart, lineEnd)],
                    x: taskGlyphX,
                    cornerRadius: lineCornerRadius,
                    isEditing: false
                )
                RoundedRectangle(cornerRadius: taskBlockCornerRadius, style: .continuous)
                    .fill(timelineGray)
                    .frame(width: taskGlyphWidth, height: pointTaskHeight)
                    .offset(x: taskGlyphX, y: anchorY - pointTaskHeight * 0.5)
                    .allowsHitTesting(false)
                focusPointOverlay(
                    centerY: anchorY,
                    x: taskGlyphX,
                    isEditing: false
                )
            }
        )
    }

    private func pointView(_ task: TaskItem) -> some View {
        let y = yPosition(for: task.startAt)
        let done = task.completionLevel == .full
        let pointX = taskGlyphX
        let pointHeight = pointTaskHeight
        let pointTopY = y - pointHeight * 0.5
        let pointCenterY = y
        let pointCornerRadius = min(taskBlockCornerRadius, pointHeight * 0.5)
        let pointHitWidth = max(taskGlyphWidth, pointTapTargetWidth)
        let pointHitHeight = max(pointHeight, pointTapTargetHeight)
        let pointHitX = pointX - (pointHitWidth - taskGlyphWidth) * 0.5 - pointTapTargetLeftExpansion
        let pointHitTopY = pointCenterY - pointHitHeight * 0.5
        let pointHitCornerRadius = min(max(pointCornerRadius + 6, 10), pointHitHeight * 0.5)
        let pointTitleFontSize: CGFloat = timelineFontSize
        let titleWidth: CGFloat = 220
        let titleHeight: CGFloat = 20
        let titleTopY = pointCenterY - titleHeight * 0.5

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: pointCornerRadius, style: .continuous)
                .fill(done ? timelineGray : inkColor)
                .frame(width: taskGlyphWidth, height: pointHeight)
                .offset(x: pointX, y: pointTopY)
                .shadow(color: inkColor.opacity(done ? 0.06 : 0.16), radius: 1.2, x: 0, y: 0)
                .overlay {
                    if editingTaskID == task.id {
                        RoundedRectangle(cornerRadius: pointCornerRadius, style: .continuous)
                            .fill(editPulseTargetColor.opacity(editPulseOn ? 0.56 : 0.0))
                            .frame(width: taskGlyphWidth, height: pointHeight)
                            .offset(x: pointX, y: pointTopY)
                    }
                }

            RoundedRectangle(cornerRadius: pointCornerRadius, style: .continuous)
                .fill(Color.clear)
                .frame(width: pointHitWidth, height: pointHitHeight)
                .contentShape(RoundedRectangle(cornerRadius: pointHitCornerRadius, style: .continuous))
                .offset(x: pointHitX, y: pointHitTopY)
                .onTapGesture {
                    guard canCompleteOnTimeline else { return }
                    store.togglePoint(task.id)
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    activateTimelineEditMode(for: task.id)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            guard canEditOnTimeline, editingTaskID == task.id else { return }
                            if dragOrigins[task.id] == nil {
                                dragOrigins[task.id] = (task.startAt, task.endAt)
                            }
                            guard let base = dragOrigins[task.id] else { return }
                            let delta = snappedMinutes(from: value.translation.height)
                            let moved = Calendar.current.date(byAdding: .minute, value: delta, to: base.0) ?? base.0
                            store.updatePointTime(
                                task.id,
                                to: moved,
                                snapMinutes: timelineSnapMinutes,
                                persist: false
                            )
                        }
                        .onEnded { _ in
                            let hadChanges = dragOrigins[task.id] != nil
                            dragOrigins[task.id] = nil
                            if hadChanges {
                                store.saveAll()
                            }
                        }
                    , including: (canEditOnTimeline && editingTaskID == task.id) ? .all : .none
                )

            Group {
                if editingTitleTaskID == task.id {
                    titleEditField(color: primaryTitleColor, fontSize: pointTitleFontSize)
                        .id("title-edit-\(task.id.uuidString)")
                } else if canEditOnTimeline {
                    HStack(spacing: 0) {
                        Text(task.displayTitle)
                            .font(.system(size: pointTitleFontSize, weight: .regular, design: .default))
                            .foregroundStyle(titleColor(for: task, defaultColor: primaryTitleColor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                beginTitleEdit(task)
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                commitDraftPoint()
                                commitTitleEdit()
                                openTaskDetailForTask(task.id)
                            }
                            .simultaneousGesture(deleteSwipeGesture(for: task.id))
                        Spacer(minLength: 0)
                    }
                } else {
                    Text(task.displayTitle)
                        .font(.system(size: pointTitleFontSize, weight: .regular, design: .default))
                        .foregroundStyle(titleColor(for: task, defaultColor: primaryTitleColor))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(width: titleWidth, height: titleHeight, alignment: .leading)
            .offset(x: taskTitleX, y: titleTopY)

        }
    }

    private func lineView(_ task: TaskItem) -> some View {
        let startY = yPosition(for: task.startAt)
        let endDate = task.endAt ?? task.startAt.addingTimeInterval(3600)
        let endY = yPosition(for: endDate)
        let endpointInset = pointTaskHeight * 0.5
        let renderedStartY = startY - endpointInset
        let height = max(pointTaskHeight, endY - startY + pointTaskHeight)
        let lineCornerRadius = min(taskBlockCornerRadius, height * 0.5)
        let focusSegments = focusIntervals(for: task)
        let focusDisplaySeconds = focusDisplayDurationSeconds(for: task, segments: focusSegments)
        let hasFocusCompletion = !focusSegments.isEmpty
        let shouldRenderFocusAsPoint =
            hasFocusCompletion &&
            focusDisplaySeconds < shortFocusPointThresholdSeconds
        let shouldRenderFocusAsBand =
            hasFocusCompletion &&
            !shouldRenderFocusAsPoint
        let focusPointY = shouldRenderFocusAsPoint
            ? focusPointCenterY(
                for: task,
                segments: focusSegments,
                fallback: startY + ((endY - startY) * 0.5)
            )
            : startY + ((endY - startY) * 0.5)
        let lineX = taskGlyphX
        let lineHitWidth = max(taskGlyphWidth, lineTapTargetWidth)
        let lineHitX = lineX - (lineHitWidth - taskGlyphWidth) * 0.5 - lineTapTargetLeftExpansion
        let titleWidth: CGFloat = 220
        let titleHeight: CGFloat = 20
        let isLineTemporallyActive = nowTime >= task.startAt && nowTime <= endDate
        let lineTitleTopY = isLineTemporallyActive
            ? yPosition(for: nowTime) - titleHeight * 0.5
            : renderedStartY
        let lineTitleColor: Color = isLineTemporallyActive
            ? primaryTitleColor
            : titleColor(for: task, defaultColor: primaryTitleColor)
        let isEditingLine = canEditOnTimeline && editingTaskID == task.id

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: lineCornerRadius, style: .continuous)
                .fill(inkColor)
                .frame(width: taskGlyphWidth, height: height)
                .offset(x: lineX, y: renderedStartY)

            Rectangle()
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(width: lineHitWidth, height: height + lineTapTargetVerticalPadding * 2)
                .offset(x: lineHitX, y: renderedStartY - lineTapTargetVerticalPadding)
                .onLongPressGesture(minimumDuration: 0.5) {
                    activateTimelineEditMode(for: task.id)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            guard canEditOnTimeline, editingTaskID == task.id else { return }
                            if value.translation.width > lineSurfaceToggleDragThreshold,
                               abs(value.translation.width) > abs(value.translation.height) {
                                dragOrigins[task.id] = nil
                                endpointDragAnchors[task.id] = nil
                                store.convertLineToSurface(task.id, snapMinutes: timelineSnapMinutes)
                                restartEditPulseAnimation()
                                return
                            }
                            if dragOrigins[task.id] == nil {
                                dragOrigins[task.id] = (task.startAt, task.endAt)
                            }
                            guard let base = dragOrigins[task.id] else { return }
                            let delta = snappedMinutes(from: value.translation.height)
                            let movedStart = Calendar.current.date(byAdding: .minute, value: delta, to: base.0) ?? base.0
                            let baseEnd = base.1 ?? base.0.addingTimeInterval(3600)
                            let movedEnd = Calendar.current.date(byAdding: .minute, value: delta, to: baseEnd) ?? baseEnd
                            store.updateRangeTaskTime(
                                task.id,
                                startAt: movedStart,
                                endAt: movedEnd,
                                snapMinutes: timelineSnapMinutes,
                                persist: false
                            )
                        }
                        .onEnded { _ in
                            let hadChanges = dragOrigins[task.id] != nil
                            dragOrigins[task.id] = nil
                            if hadChanges {
                                store.saveAll()
                            }
                        }
                    , including: (canEditOnTimeline && editingTaskID == task.id) ? .all : .none
                )
                .onTapGesture {
                    guard canCompleteOnTimeline else { return }
                    guard editingTaskID == nil else { return }
                    store.cycleLine(task.id)
                }

            manualLineOverlay(
                task: task,
                height: height,
                y: renderedStartY,
                x: lineX,
                cornerRadius: lineCornerRadius
            )

            if shouldRenderFocusAsBand {
                focusLineOverlay(
                    task: task,
                    endDate: endDate,
                    height: height,
                    startY: renderedStartY,
                    segments: focusSegments,
                    x: lineX,
                    cornerRadius: lineCornerRadius,
                    isEditing: isEditingLine
                )
            }

            if shouldRenderFocusAsPoint {
                focusPointOverlay(
                    centerY: focusPointY,
                    x: lineX,
                    isEditing: isEditingLine
                )
            }

            if editingTaskID == task.id {
                RoundedRectangle(cornerRadius: lineCornerRadius, style: .continuous)
                    .fill(editPulseTargetColor.opacity(editPulseOn ? 0.52 : 0.0))
                    .frame(width: taskGlyphWidth, height: height)
                    .offset(x: lineX, y: renderedStartY)
                    .allowsHitTesting(false)
            }

            if isEditingLine {
                // Make endpoint controls finger-sized to reduce accidental whole-line drags.
                let endpointHitWidth: CGFloat = 40
                let endpointHitHeight: CGFloat = 52
                let endpointHitX = lineX + (taskGlyphWidth - endpointHitWidth) * 0.5

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(width: endpointHitWidth, height: endpointHitHeight)
                    .offset(x: endpointHitX, y: startY - endpointHitHeight * 0.5)
                    .onTapGesture {
                        endpointDragAnchors[task.id] = nil
                        store.convertLineToPoint(task.id, keep: .end, snapMinutes: timelineSnapMinutes)
                        restartEditPulseAnimation()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                guard canEditOnTimeline, editingTaskID == task.id else { return }
                                if value.translation.width > lineSurfaceToggleDragThreshold,
                                   abs(value.translation.width) > abs(value.translation.height) {
                                    dragOrigins[task.id] = nil
                                    endpointDragAnchors[task.id] = nil
                                    store.convertLineToSurface(task.id, snapMinutes: timelineSnapMinutes)
                                    restartEditPulseAnimation()
                                    return
                                }
                                let step = TimeInterval(max(1, timelineSnapMinutes) * 60)
                                let currentEnd = task.endAt ?? task.startAt.addingTimeInterval(step)
                                if endpointDragAnchors[task.id] == nil {
                                    endpointDragAnchors[task.id] = (start: task.startAt, end: currentEnd)
                                }
                                guard let base = endpointDragAnchors[task.id] else { return }
                                let delta = snappedMinutes(from: value.translation.height)
                                let movedStart = Calendar.current.date(byAdding: .minute, value: delta, to: base.start) ?? base.start
                                store.updateRangeTaskEndpoint(
                                    task.id,
                                    endpoint: .start,
                                    to: movedStart,
                                    snapMinutes: timelineSnapMinutes,
                                    persist: false
                                )
                            }
                            .onEnded { _ in
                                let hadChanges = endpointDragAnchors[task.id] != nil
                                endpointDragAnchors[task.id] = nil
                                if hadChanges {
                                    store.saveAll()
                                }
                            }
                    )

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(width: endpointHitWidth, height: endpointHitHeight)
                    .offset(x: endpointHitX, y: endY - endpointHitHeight * 0.5)
                    .onTapGesture {
                        endpointDragAnchors[task.id] = nil
                        store.convertLineToPoint(task.id, keep: .start, snapMinutes: timelineSnapMinutes)
                        restartEditPulseAnimation()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                guard canEditOnTimeline, editingTaskID == task.id else { return }
                                if value.translation.width > lineSurfaceToggleDragThreshold,
                                   abs(value.translation.width) > abs(value.translation.height) {
                                    dragOrigins[task.id] = nil
                                    endpointDragAnchors[task.id] = nil
                                    store.convertLineToSurface(task.id, snapMinutes: timelineSnapMinutes)
                                    restartEditPulseAnimation()
                                    return
                                }
                                let step = TimeInterval(max(1, timelineSnapMinutes) * 60)
                                let currentEnd = task.endAt ?? task.startAt.addingTimeInterval(step)
                                if endpointDragAnchors[task.id] == nil {
                                    endpointDragAnchors[task.id] = (start: task.startAt, end: currentEnd)
                                }
                                guard let base = endpointDragAnchors[task.id] else { return }
                                let delta = snappedMinutes(from: value.translation.height)
                                let movedEnd = Calendar.current.date(byAdding: .minute, value: delta, to: base.end) ?? base.end
                                store.updateRangeTaskEndpoint(
                                    task.id,
                                    endpoint: .end,
                                    to: movedEnd,
                                    snapMinutes: timelineSnapMinutes,
                                    persist: false
                                )
                            }
                            .onEnded { _ in
                                let hadChanges = endpointDragAnchors[task.id] != nil
                                endpointDragAnchors[task.id] = nil
                                if hadChanges {
                                    store.saveAll()
                                }
                            }
                    )
            }

            Group {
                if editingTitleTaskID == task.id {
                    titleEditField(color: lineTitleColor)
                        .id("title-edit-\(task.id.uuidString)")
                } else if canEditOnTimeline {
                    HStack(spacing: 0) {
                        Text(task.displayTitle)
                            .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                            .foregroundStyle(lineTitleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                beginTitleEdit(task)
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                commitDraftPoint()
                                commitTitleEdit()
                                openTaskDetailForTask(task.id)
                            }
                            .simultaneousGesture(deleteSwipeGesture(for: task.id))
                        Spacer(minLength: 0)
                    }
                } else {
                    Text(task.displayTitle)
                        .font(.system(size: timelineFontSize, weight: .regular, design: .default))
                        .foregroundStyle(lineTitleColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(width: titleWidth, height: titleHeight, alignment: .leading)
            .offset(x: taskTitleX, y: lineTitleTopY)

        }
        .allowsHitTesting(!isPointEditingMode)
    }

    private func manualLineOverlay(
        task: TaskItem,
        height: CGFloat,
        y: CGFloat,
        x: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        let capRadius = min(cornerRadius, height * 0.5)
        let grayHeight: CGFloat
        switch task.completionLevel {
        case .none:
            grayHeight = 0
        case .half:
            // Keep the rounded cap center near the visual 50% mark.
            grayHeight = min(height, (height / 2) + (capRadius * 0.5))
        case .full:
            grayHeight = height
        }

        return RoundedRectangle(cornerRadius: capRadius, style: .continuous)
            .fill(timelineGray)
            .frame(width: taskGlyphWidth, height: grayHeight)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    private func halfPointOverlay(centerY: CGFloat, x: CGFloat, isEditing: Bool) -> some View {
        let pointColor: Color
        if isEditing {
            pointColor = editPulseOn ? editPulseTargetColor.opacity(0.88) : timelineGray
        } else {
            pointColor = timelineGray
        }

        return RoundedRectangle(cornerRadius: pointTaskHeight * 0.5, style: .continuous)
            .fill(pointColor)
            .frame(width: taskGlyphWidth, height: pointTaskHeight)
            .offset(x: x, y: centerY - (pointTaskHeight * 0.5))
            .allowsHitTesting(false)
    }

    private func focusPointOverlay(centerY: CGFloat, x: CGFloat, isEditing: Bool) -> some View {
        let diameter = min(taskGlyphWidth, pointTaskHeight)
        let primaryExpand = diameter * 0.39
        let secondaryExpand = diameter * 0.64
        let primaryBlur = diameter * 0.425
        let secondaryBlur = diameter * 0.725
        let glowInset: CGFloat = max(22, secondaryExpand + secondaryBlur + 6)

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.976 + 0.024 * CGFloat(0.5 + 0.5 * sin(time * 0.72))
            let editBoost: CGFloat = isEditing ? (editPulseOn ? 1.08 : 0.96) : 1.0
            let gradientDrift = CGFloat(sin(time * 0.38)) * 0.008
            let primaryHaloOpacity: CGFloat = colorScheme == .dark ? 0.165 : 0.132
            let secondaryHaloOpacity: CGFloat = colorScheme == .dark ? 0.090 : 0.076

            Canvas { graphics, size in
                let pointRect = CGRect(
                    x: glowInset + (taskGlyphWidth - diameter) * 0.5,
                    y: glowInset + (pointTaskHeight - diameter) * 0.5,
                    width: diameter,
                    height: diameter
                )

                let gradientStart = CGPoint(
                    x: pointRect.minX + pointRect.width * (0.14 + gradientDrift),
                    y: pointRect.minY + pointRect.height * 0.10
                )
                let gradientEnd = CGPoint(
                    x: pointRect.maxX - pointRect.width * (0.14 - gradientDrift),
                    y: pointRect.maxY - pointRect.height * 0.10
                )
                let corePath = Path(ellipseIn: pointRect)

                let primaryGlowRect = pointRect.insetBy(dx: -primaryExpand, dy: -primaryExpand)
                let secondaryGlowRect = pointRect.insetBy(dx: -secondaryExpand, dy: -secondaryExpand)
                let corePhase = CGFloat(sin(time * 0.21)) * 0.04
                let primaryGlowGradient = Gradient(colors: [
                    focusHaloPeach.opacity(primaryHaloOpacity * pulse * editBoost),
                    focusHaloPink.opacity(primaryHaloOpacity * pulse * editBoost),
                    focusHaloLilac.opacity(primaryHaloOpacity * pulse * editBoost),
                    focusHaloBlue.opacity(primaryHaloOpacity * pulse * editBoost),
                    focusHaloMint.opacity(primaryHaloOpacity * pulse * editBoost)
                ])
                let secondaryGlowGradient = Gradient(colors: [
                    focusHaloPeach.opacity(secondaryHaloOpacity * pulse * editBoost),
                    focusHaloPink.opacity(secondaryHaloOpacity * pulse * editBoost),
                    focusHaloLilac.opacity(secondaryHaloOpacity * pulse * editBoost),
                    focusHaloBlue.opacity(secondaryHaloOpacity * pulse * editBoost),
                    focusHaloMint.opacity(secondaryHaloOpacity * pulse * editBoost)
                ])

                graphics.drawLayer { layer in
                    layer.blendMode = .screen
                    layer.addFilter(.blur(radius: primaryBlur))
                    layer.fill(
                        Path(ellipseIn: primaryGlowRect),
                        with: .linearGradient(
                            primaryGlowGradient,
                            startPoint: gradientStart,
                            endPoint: gradientEnd
                        )
                    )
                }
                graphics.drawLayer { layer in
                    layer.blendMode = .screen
                    layer.addFilter(.blur(radius: secondaryBlur))
                    layer.fill(
                        Path(ellipseIn: secondaryGlowRect),
                        with: .linearGradient(
                            secondaryGlowGradient,
                            startPoint: gradientStart,
                            endPoint: gradientEnd
                        )
                    )
                }
                drawLightHaloVariation(
                    &graphics,
                    rect: pointRect,
                    phase: corePhase
                )
                drawLightFocusCore(
                    &graphics,
                    corePath: corePath,
                    rect: pointRect,
                    phase: corePhase,
                    drift: gradientDrift
                )
            }
            .frame(width: taskGlyphWidth + glowInset * 2, height: pointTaskHeight + glowInset * 2)
            .offset(x: x - glowInset, y: centerY - (pointTaskHeight * 0.5) - glowInset)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private func focusLineOverlay(
        task: TaskItem,
        endDate: Date,
        height: CGFloat,
        startY: CGFloat,
        segments: [(Date, Date)],
        x: CGFloat,
        cornerRadius: CGFloat,
        isEditing: Bool
    ) -> some View {
        let total = max(1, endDate.timeIntervalSince(task.startAt))
        let normalizedSegments: [(offset: CGFloat, ratio: CGFloat)] = segments
            .map { seg in
                let offsetRatio = max(0, seg.0.timeIntervalSince(task.startAt) / total)
                let ratio = max(0, seg.1.timeIntervalSince(seg.0) / total)
                return (CGFloat(offsetRatio), CGFloat(ratio))
            }
            .filter { $0.ratio > 0 }

        let primaryExpandX = taskGlyphWidth * 0.35
        let primaryExpandY = pointTaskHeight * 0.44
        let secondaryExpandX = taskGlyphWidth * 0.59
        let secondaryExpandY = pointTaskHeight * 0.81
        let primaryBlur = pointTaskHeight * 0.47
        let secondaryBlur = pointTaskHeight * 0.70
        let glowInsetX: CGFloat = max(24, secondaryExpandX + secondaryBlur + 7)
        let glowInsetY: CGFloat = max(29, secondaryExpandY + secondaryBlur + 8)
        let canvasWidth = taskGlyphWidth + glowInsetX * 2
        let canvasHeight = height + glowInsetY * 2

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let disturbance = focusDisturbance(at: context.date)
            let flow = focusFlow(at: context.date)
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.93 + 0.12 * CGFloat(0.5 + 0.5 * sin(time * 1.35))
            let editBoost: CGFloat = isEditing ? (editPulseOn ? 1.14 : 0.90) : 1.0
            let flowPower = min(1.2, sqrt(flow.width * flow.width + flow.height * flow.height))
            let motionBoost = 1 + min(0.52, disturbance * 0.64 + flowPower * 0.36)

            Canvas { graphics, size in
                for segment in normalizedSegments {
                    let segmentHeight = max(2, height * segment.ratio)
                    let segmentY = glowInsetY + height * segment.offset
                    let segmentRect = CGRect(
                        x: glowInsetX,
                        y: segmentY,
                        width: taskGlyphWidth,
                        height: segmentHeight
                    )
                    let segmentCornerRadius = min(cornerRadius, segmentHeight * 0.5)
                    drawFocusGlowBand(
                        &graphics,
                        rect: segmentRect,
                        cornerRadius: segmentCornerRadius,
                        time: time,
                        pulse: pulse * editBoost,
                        flow: flow,
                        motionBoost: motionBoost,
                        primaryExpandX: primaryExpandX,
                        primaryExpandY: primaryExpandY,
                        secondaryExpandX: secondaryExpandX,
                        secondaryExpandY: secondaryExpandY,
                        primaryBlur: primaryBlur,
                        secondaryBlur: secondaryBlur
                    )
                }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .offset(x: x - glowInsetX, y: startY - glowInsetY)
            .allowsHitTesting(false)
        }
    }

    private func drawFocusGlowBand(
        _ graphics: inout GraphicsContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        time: TimeInterval,
        pulse: CGFloat,
        flow: CGSize,
        motionBoost: CGFloat,
        primaryExpandX: CGFloat,
        primaryExpandY: CGFloat,
        secondaryExpandX: CGFloat,
        secondaryExpandY: CGFloat,
        primaryBlur: CGFloat,
        secondaryBlur: CGFloat
    ) {
        let flowX = max(-1, min(1, flow.width))

        let gradientShift = CGFloat(sin(time * 0.68)) * 0.03 + flowX * 0.03
        let gradientStart = CGPoint(
            x: rect.minX + rect.width * (0.08 + gradientShift),
            y: rect.minY + rect.height * 0.04
        )
        let gradientEnd = CGPoint(
            x: rect.maxX - rect.width * (0.06 - gradientShift),
            y: rect.maxY - rect.height * 0.04
        )
        let corePath = Path(roundedRect: rect, cornerRadius: cornerRadius)

        let primaryHaloOpacity: CGFloat = colorScheme == .dark ? 0.145 : 0.120
        let secondaryHaloOpacity: CGFloat = colorScheme == .dark ? 0.082 : 0.070
        let primaryGlowRect = rect.insetBy(dx: -primaryExpandX, dy: -primaryExpandY)
        let secondaryGlowRect = rect.insetBy(dx: -secondaryExpandX, dy: -secondaryExpandY)
        let primaryGlowCorner = cornerRadius + primaryExpandY
        let secondaryGlowCorner = cornerRadius + secondaryExpandY
        let corePhase = CGFloat(sin(time * 0.24)) * 0.045 + flowX * 0.025
        let primaryGlowGradient = Gradient(colors: [
            focusHaloPeach.opacity(primaryHaloOpacity * pulse * motionBoost),
            focusHaloPink.opacity(primaryHaloOpacity * pulse * motionBoost),
            focusHaloLilac.opacity(primaryHaloOpacity * pulse * motionBoost),
            focusHaloBlue.opacity(primaryHaloOpacity * pulse * motionBoost),
            focusHaloMint.opacity(primaryHaloOpacity * pulse * motionBoost)
        ])
        let secondaryGlowGradient = Gradient(colors: [
            focusHaloPeach.opacity(secondaryHaloOpacity * pulse * motionBoost),
            focusHaloPink.opacity(secondaryHaloOpacity * pulse * motionBoost),
            focusHaloLilac.opacity(secondaryHaloOpacity * pulse * motionBoost),
            focusHaloBlue.opacity(secondaryHaloOpacity * pulse * motionBoost),
            focusHaloMint.opacity(secondaryHaloOpacity * pulse * motionBoost)
        ])

        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: primaryBlur))
            layer.fill(
                Path(roundedRect: primaryGlowRect, cornerRadius: primaryGlowCorner),
                with: .linearGradient(
                    primaryGlowGradient,
                    startPoint: gradientStart,
                    endPoint: gradientEnd
                )
            )
        }
        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: secondaryBlur))
            layer.fill(
                Path(roundedRect: secondaryGlowRect, cornerRadius: secondaryGlowCorner),
                with: .linearGradient(
                    secondaryGlowGradient,
                    startPoint: gradientStart,
                    endPoint: gradientEnd
                )
            )
        }
        drawLightHaloVariation(
            &graphics,
            rect: rect,
            phase: corePhase
        )
        drawLightFocusCore(
            &graphics,
            corePath: corePath,
            rect: rect,
            phase: corePhase,
            drift: gradientShift
        )
    }

    private func clampedUnit(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func focusCoreGradient(phase: CGFloat) -> Gradient {
        let shift = max(-0.05, min(0.05, phase))
        return Gradient(stops: [
            .init(color: focusGlowPeach, location: 0.02),
            .init(color: focusGlowPeach, location: clampedUnit(0.13 + shift * 0.30)),
            .init(color: focusGlowPink, location: clampedUnit(0.31 + shift * 0.48)),
            .init(color: focusGlowLilac, location: clampedUnit(0.57 + shift * 0.28)),
            .init(color: focusGlowBlue, location: clampedUnit(0.80 + shift * 0.18)),
            .init(color: focusGlowMint, location: 0.99)
        ])
    }

    private func focusAccentGradient(phase: CGFloat) -> Gradient {
        let shift = max(-0.04, min(0.04, phase))
        return Gradient(stops: [
            .init(color: focusGlowPink.opacity(0.22), location: clampedUnit(0.16 + shift * 0.60)),
            .init(color: focusGlowLilac.opacity(0.27), location: clampedUnit(0.44 + shift * 0.40)),
            .init(color: focusGlowBlue.opacity(0.24), location: clampedUnit(0.72 + shift * 0.26)),
            .init(color: focusGlowMint.opacity(0.18), location: 0.95)
        ])
    }

    private func focusLightCoreGradient(phase: CGFloat) -> Gradient {
        let shift = max(-0.08, min(0.08, phase))
        return Gradient(stops: [
            .init(color: focusGlowPeach.opacity(0.97), location: clampedUnit(0.01 + shift * 0.22)),
            .init(color: focusGlowPink.opacity(0.96), location: clampedUnit(0.27 + shift * 0.36)),
            .init(color: focusGlowLilac.opacity(0.98), location: clampedUnit(0.50 + shift * 0.24)),
            .init(color: focusGlowBlue.opacity(0.97), location: clampedUnit(0.73 + shift * 0.20)),
            .init(color: focusGlowMint.opacity(0.96), location: clampedUnit(0.95 + shift * 0.12))
        ])
    }

    private func focusLightHaloGradient(phase: CGFloat, alpha: CGFloat) -> Gradient {
        let shift = max(-0.10, min(0.10, phase))
        return Gradient(stops: [
            .init(color: focusHaloPeach.opacity(0.86 * alpha), location: clampedUnit(0.04 + shift * 0.20)),
            .init(color: focusHaloPink.opacity(0.92 * alpha), location: clampedUnit(0.30 + shift * 0.40)),
            .init(color: focusHaloLilac.opacity(0.96 * alpha), location: clampedUnit(0.52 + shift * 0.30)),
            .init(color: focusHaloBlue.opacity(0.90 * alpha), location: clampedUnit(0.72 + shift * 0.24)),
            .init(color: focusHaloMint.opacity(0.84 * alpha), location: clampedUnit(0.94 + shift * 0.16))
        ])
    }

    private func drawLightHaloVariation(
        _ graphics: inout GraphicsContext,
        rect: CGRect,
        phase: CGFloat
    ) {
        let shift = max(-0.10, min(0.10, phase))
        // Keep halo soft and organic to avoid visible horizontal cutoff lines.
        let nearRect = rect.insetBy(dx: -rect.width * 0.14, dy: -rect.height * 0.145)
        let farRect = rect.insetBy(dx: -rect.width * 0.225, dy: -rect.height * 0.245)

        let nearStart = CGPoint(
            x: nearRect.minX + nearRect.width * (0.18 + shift * 0.26),
            y: nearRect.minY + nearRect.height * (0.16 - shift * 0.10)
        )
        let nearEnd = CGPoint(
            x: nearRect.maxX - nearRect.width * (0.14 - shift * 0.20),
            y: nearRect.maxY - nearRect.height * (0.14 + shift * 0.10)
        )
        let farStart = CGPoint(
            x: farRect.minX + farRect.width * (0.20 - shift * 0.18),
            y: farRect.minY + farRect.height * (0.18 + shift * 0.12)
        )
        let farEnd = CGPoint(
            x: farRect.maxX - farRect.width * (0.18 + shift * 0.14),
            y: farRect.maxY - farRect.height * (0.16 - shift * 0.10)
        )

        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: max(2.0, rect.width * 0.26)))
            layer.fill(
                Path(ellipseIn: nearRect),
                with: .linearGradient(
                    focusLightHaloGradient(phase: shift, alpha: 0.115),
                    startPoint: nearStart,
                    endPoint: nearEnd
                )
            )
        }
        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: max(2.6, rect.width * 0.33)))
            layer.fill(
                Path(ellipseIn: farRect),
                with: .linearGradient(
                    focusLightHaloGradient(phase: -shift * 0.46, alpha: 0.060),
                    startPoint: farStart,
                    endPoint: farEnd
                )
            )
        }
    }

    private func rotatedEllipsePath(in rect: CGRect, degrees: CGFloat) -> Path {
        let radians = degrees * .pi / 180
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        return Path(ellipseIn: rect).applying(transform)
    }

    private func drawLightFocusCore(
        _ graphics: inout GraphicsContext,
        corePath: Path,
        rect: CGRect,
        phase: CGFloat,
        drift: CGFloat
    ) {
        let shift = max(-0.11, min(0.11, phase + drift * 1.9))
        let baseStart = CGPoint(
            x: rect.minX + rect.width * (0.06 + shift * 0.42),
            y: rect.minY - rect.height * (0.06 - shift * 0.16)
        )
        let baseEnd = CGPoint(
            x: rect.maxX - rect.width * (0.04 - shift * 0.30),
            y: rect.maxY + rect.height * (0.04 + shift * 0.16)
        )

        graphics.fill(
            corePath,
            with: .linearGradient(
                focusLightCoreGradient(phase: shift),
                startPoint: baseStart,
                endPoint: baseEnd
            )
        )

        let textureBlur = max(0.275, min(rect.width, rect.height) * 0.08)
        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.clip(to: corePath)
            layer.addFilter(.blur(radius: textureBlur))
            layer.fill(
                corePath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color.white.opacity(0.07), location: 0.00),
                        .init(color: Color.white.opacity(0.04), location: 0.36),
                        .init(color: Color.white.opacity(0.00), location: 1.00)
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
            layer.fill(
                rotatedEllipsePath(
                    in: CGRect(
                        x: rect.minX - rect.width * (0.10 - shift * 0.08),
                        y: rect.minY + rect.height * (0.42 - shift * 0.06),
                        width: rect.width * 1.10,
                        height: rect.height * 0.70
                    ),
                    degrees: -8 + shift * 42
                ),
                with: .color(focusHaloBlue.opacity(0.06))
            )
        }

        drawLightInnerGlow(&graphics, corePath: corePath, rect: rect, phase: shift)
    }

    private func drawLightInnerGlow(
        _ graphics: inout GraphicsContext,
        corePath: Path,
        rect: CGRect,
        phase: CGFloat
    ) {
        let rimWidth = max(0.88, min(rect.width, rect.height) * 0.098)
        let edgeGradient = Gradient(stops: [
            .init(color: Color.white.opacity(0.28), location: clampedUnit(0.06 + phase * 0.20)),
            .init(color: focusHaloPink.opacity(0.20), location: clampedUnit(0.34 + phase * 0.26)),
            .init(color: focusHaloLilac.opacity(0.22), location: clampedUnit(0.54 + phase * 0.18)),
            .init(color: focusHaloBlue.opacity(0.19), location: clampedUnit(0.76 + phase * 0.12)),
            .init(color: focusHaloMint.opacity(0.15), location: 0.96)
        ])
        let secondaryRim = max(0.50, rimWidth * 0.58)
        let softOuterWidth = rimWidth * 0.43
        let softOuterBlur = max(0.14, rimWidth * 0.22)
        let softOuterOpacity = colorScheme == .light ? 0.46 : 0.20
        let brightRimWidth = max(0.46, rimWidth * 0.72)
        let brightStart = CGPoint(x: rect.minX, y: rect.minY)
        let brightEnd = CGPoint(x: rect.maxX, y: rect.maxY)

        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: softOuterBlur))
            layer.stroke(
                corePath,
                with: .color(Color.white.opacity(softOuterOpacity)),
                lineWidth: softOuterWidth
            )
        }

        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.clip(to: corePath)
            layer.addFilter(.blur(radius: max(0.18, rimWidth * 0.21)))
            layer.stroke(
                corePath,
                with: .linearGradient(
                    edgeGradient,
                    startPoint: CGPoint(x: rect.minX, y: rect.minY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                ),
                lineWidth: rimWidth
            )
            layer.stroke(
                corePath,
                with: .color(Color.white.opacity(colorScheme == .light ? 0.18 : 0.10)),
                lineWidth: secondaryRim
            )
        }

        graphics.drawLayer { layer in
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: max(0.14, brightRimWidth * 0.10)))
            if colorScheme == .light {
                layer.stroke(
                    corePath,
                    with: .color(Color.white.opacity(0.56)),
                    lineWidth: brightRimWidth
                )
            } else {
                layer.stroke(
                    corePath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color.white.opacity(0.46), location: 0.00),
                            .init(color: Color.white.opacity(0.34), location: 0.42),
                            .init(color: Color.white.opacity(0.24), location: 1.00)
                        ]),
                        startPoint: brightStart,
                        endPoint: brightEnd
                    ),
                    lineWidth: brightRimWidth
                )
            }
        }
    }

    private var focusHaloPink: Color {
        colorScheme == .light
            ? Color(.sRGB, red: 0.88, green: 0.60, blue: 0.95, opacity: 1)
            : focusGlowPink
    }

    private var focusHaloLilac: Color {
        colorScheme == .light
            ? Color(.sRGB, red: 0.70, green: 0.60, blue: 0.95, opacity: 1)
            : focusGlowLilac
    }

    private var focusHaloBlue: Color {
        colorScheme == .light
            ? Color(.sRGB, red: 0.56, green: 0.74, blue: 0.96, opacity: 1)
            : focusGlowBlue
    }

    private var focusHaloMint: Color {
        colorScheme == .light
            ? Color(.sRGB, red: 0.53, green: 0.84, blue: 0.77, opacity: 1)
            : focusGlowMint
    }

    private var focusHaloPeach: Color {
        colorScheme == .light
            ? Color(.sRGB, red: 0.95, green: 0.73, blue: 0.65, opacity: 1)
            : focusGlowPeach
    }

    private var focusGlowPink: Color {
        Color(.sRGB, red: 0.95, green: 0.77, blue: 0.98, opacity: 1)
    }

    private var focusGlowLilac: Color {
        Color(.sRGB, red: 0.83, green: 0.79, blue: 1.0, opacity: 1)
    }

    private var focusGlowBlue: Color {
        Color(.sRGB, red: 0.75, green: 0.87, blue: 1.0, opacity: 1)
    }

    private var focusGlowMint: Color {
        Color(.sRGB, red: 0.76, green: 0.92, blue: 0.87, opacity: 1)
    }

    private var focusGlowPeach: Color {
        Color(.sRGB, red: 0.98, green: 0.83, blue: 0.77, opacity: 1)
    }

    private func registerFocusDisturbanceSample(at y: CGFloat) {
        let now = Date()
        defer {
            lastScrollSampleY = y
            lastScrollSampleAt = now
        }

        guard lastScrollSampleY.isFinite, lastScrollSampleAt != .distantPast else { return }
        let dt = now.timeIntervalSince(lastScrollSampleAt)
        guard dt > 0 else { return }

        let signedVelocity = (y - lastScrollSampleY) / CGFloat(dt)
        let speed = abs(signedVelocity)
        let impulse = min(1, speed / 1400)
        let directional = max(-1, min(1, signedVelocity / 900))
        guard impulse > 0.001 || abs(directional) > 0.001 else { return }

        focusDisturbanceBase = max(focusDisturbanceBase * 0.72, impulse)
        focusFlowYBase = max(-1, min(1, focusFlowYBase * 0.45 + directional * 0.95))
        focusFlowXBase = max(-1, min(1, focusFlowXBase * 0.52 + (-directional * 0.40)))
        focusDisturbanceUpdatedAt = now
    }

    private func focusDisturbance(at date: Date) -> CGFloat {
        guard focusDisturbanceUpdatedAt != .distantPast else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(focusDisturbanceUpdatedAt))
        let decayed = Double(focusDisturbanceBase) * exp(-elapsed * 3.4)
        return CGFloat(min(max(decayed, 0), 1))
    }

    private func focusFlow(at date: Date) -> CGSize {
        guard focusDisturbanceUpdatedAt != .distantPast else { return .zero }
        let elapsed = max(0, date.timeIntervalSince(focusDisturbanceUpdatedAt))
        let decay = CGFloat(exp(-elapsed * 1.65))
        return CGSize(width: focusFlowXBase * decay, height: focusFlowYBase * decay)
    }

    private func focusDisplayDurationSeconds(for task: TaskItem, segments: [(Date, Date)]) -> TimeInterval {
        let taskEnd = task.endAt ?? task.startAt
        guard taskEnd > task.startAt else { return 0 }

        let total = segments
            .map { segment in
                let start = max(segment.0, task.startAt)
                let end = min(segment.1, taskEnd)
                return max(0, end.timeIntervalSince(start))
            }
            .reduce(0.0) { partial, value in
                partial + value
            }

        guard total > 0 else { return 0 }
        return max(minimumFocusDisplaySeconds, total)
    }

    private func focusPointCenterY(for task: TaskItem, segments: [(Date, Date)], fallback: CGFloat) -> CGFloat {
        let taskEnd = task.endAt ?? task.startAt
        guard taskEnd > task.startAt else { return fallback }

        for segment in segments.sorted(by: { $0.0 < $1.0 }) {
            let start = max(segment.0, task.startAt)
            let end = min(segment.1, taskEnd)
            guard end > start else { continue }
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) * 0.5)
            return yPosition(for: mid)
        }

        return fallback
    }

    private func focusIntervals(for task: TaskItem) -> [(Date, Date)] {
        store.focusSessions
            .filter { $0.taskId == task.id }
            .sorted { $0.startAt < $1.startAt }
            .map { ($0.startAt, $0.endAt) }
    }

    private func titleColor(for task: TaskItem, defaultColor: Color) -> Color {
        guard isCompleted(task) else { return defaultColor }
        return timelineGray
    }

    private func surfaceTitleColor(titleTopY: CGFloat) -> Color {
        let nowY = yPosition(for: nowTime)
        return titleTopY < nowY ? timelineGray : inkColor
    }

    private func isCompleted(_ task: TaskItem) -> Bool {
        if task.status == .completed {
            return true
        }
        switch task.type {
        case .line:
            return task.completionLevel == .full || task.completionLevel == .half
        case .point, .surface:
            return task.completionLevel == .full
        }
    }

    private func isAxisCreationArea(_ location: CGPoint) -> Bool {
        abs(location.x - axisX) <= axisCreationTapHalfWidth
    }

    private func isAxisSlotAvailable(at date: Date) -> Bool {
        let tapY = yPosition(for: date)
        for task in store.tasks {
            guard task.type == .point else { continue }
            let pointY = yPosition(for: task.startAt)
            if abs(pointY - tapY) <= 12 {
                return false
            }
        }
        return true
    }

    private func beginDraftPoint(atViewportY viewportY: CGFloat) {
        let rawDate = dateAtViewportY(viewportY)
        let snappedDate = store.snap(rawDate, toStepMinutes: timelineSnapMinutes)
        draftQuickCreate = DraftQuickCreate(date: snappedDate, title: "")
        requestDraftInputFocus()
    }

    private func requestDraftInputFocus() {
        draftFocusRequestID += 1
        let requestID = draftFocusRequestID
        isDraftInputFocused = false
        let attempts: [TimeInterval] = [0.0, 0.02, 0.08, 0.18]
        for delay in attempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard requestID == draftFocusRequestID else { return }
                guard draftQuickCreate != nil else { return }
                isDraftInputFocused = true
            }
        }
    }

    private func commitDraftPoint(suppressFollowupTap: Bool = false) {
        guard let draft = draftQuickCreate else { return }
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDate = draft.date
        resetRecenterTapState()

        // Only keyboard submit needs follow-up tap suppression.
        if suppressFollowupTap {
            suppressTapUntil = Date().addingTimeInterval(0.45)
            // Keep timeline locked while the keyboard is transitioning out.
            isCommittingDraftPoint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                isCommittingDraftPoint = false
            }
        }

        guard !trimmed.isEmpty else {
            draftFocusRequestID += 1
            draftQuickCreate = nil
            isDraftInputFocused = false
            return
        }

        // Create first, then exit input mode; this keeps the task locked to the same slot.
        store.createQuickPoint(at: finalDate, title: trimmed, shouldSnap: false)
        draftFocusRequestID += 1
        draftQuickCreate = nil
        isDraftInputFocused = false
    }

    private func beginTitleEdit(_ task: TaskItem) {
        guard canEditOnTimeline else { return }
        commitDraftPoint()
        editingTaskID = nil
        editingTitleTaskID = task.id
        editingTitleText = task.title
        DispatchQueue.main.async {
            isTitleInputFocused = true
        }
    }

    private func commitTitleEdit() {
        guard let taskID = editingTitleTaskID else { return }
        let newTitle = editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameTask(taskID, title: newTitle)
        resetRecenterTapState()
        editingTitleTaskID = nil
        editingTitleText = ""
        isTitleInputFocused = false
    }

    private func handleTap(at location: CGPoint, viewportY: CGFloat) {
        guard Date() >= suppressTapUntil else { return }
        guard canCreateOnTimeline else { return }
        guard isAxisCreationArea(location) else {
            if canEditOnTimeline, editingTaskID != nil {
                editingTaskID = nil
            }
            return
        }
        let tappedDate = dateAtViewportY(viewportY)
        if let selectedTaskID = editingTaskID,
           let selected = store.task(with: selectedTaskID),
           selected.type == .point {
            let snappedDate = store.snap(tappedDate, toStepMinutes: timelineSnapMinutes)
            guard abs(snappedDate.timeIntervalSince(selected.startAt)) >= 60 else { return }
            store.convertPointToLine(
                selectedTaskID,
                endAt: snappedDate,
                snapMinutes: timelineSnapMinutes
            )
            restartEditPulseAnimation()
            return
        }

        guard isAxisSlotAvailable(at: tappedDate) else { return }
        if canEditOnTimeline, editingTaskID != nil {
            editingTaskID = nil
        }
        beginDraftPoint(atViewportY: viewportY)
    }

    private func handleSurfaceLongPress(at location: CGPoint, viewportY: CGFloat) {
        guard canEditOnTimeline else { return }
        guard editingTitleTaskID == nil else { return }
        guard !isAxisCreationArea(location) else { return }
        // Give point/line long-press precedence over surface selection.
        guard timelineTaskGlyphHitID(at: location, viewportY: viewportY) == nil else { return }

        let left = surfaceBackgroundX
        let right = surfaceBackgroundX + surfaceBackgroundWidth
        guard location.x >= left, location.x <= right else { return }

        let surfaceTasks = store.tasks.filter { $0.type == .surface }
        guard let hitSurface = surfaceTasks.last(where: { task in
            let startY = yPosition(for: task.startAt)
            let endY = yPosition(for: task.endAt ?? task.startAt.addingTimeInterval(3600))
            let height = max(46, endY - startY)
            return viewportY >= startY && viewportY <= (startY + height)
        }) else { return }

        activateTimelineEditMode(for: hitSurface.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        restartEditPulseAnimation()
    }

    private func timelineTaskGlyphHitID(at location: CGPoint, viewportY: CGFloat) -> UUID? {
        let x = location.x
        let y = viewportY

        for task in store.tasks.reversed() {
            switch task.type {
            case .point:
                let centerY = yPosition(for: task.startAt)
                let hitLeft = taskGlyphX - pointTapTargetLeftExpansion
                let hitTop = centerY - pointTapTargetHeight * 0.5
                if x >= hitLeft,
                   x <= hitLeft + pointTapTargetWidth,
                   y >= hitTop,
                   y <= hitTop + pointTapTargetHeight {
                    return task.id
                }
            case .line:
                let startY = yPosition(for: task.startAt)
                let endDate = task.endAt ?? task.startAt.addingTimeInterval(3600)
                let endY = yPosition(for: endDate)
                let endpointInset = pointTaskHeight * 0.5
                let renderedStartY = startY - endpointInset
                let lineHeight = max(pointTaskHeight, endY - startY + pointTaskHeight)
                let hitWidth = max(taskGlyphWidth, lineTapTargetWidth)
                let hitLeft = taskGlyphX - (hitWidth - taskGlyphWidth) * 0.5 - lineTapTargetLeftExpansion
                let hitTop = renderedStartY - lineTapTargetVerticalPadding
                let hitHeight = lineHeight + lineTapTargetVerticalPadding * 2
                if x >= hitLeft,
                   x <= hitLeft + hitWidth,
                   y >= hitTop,
                   y <= hitTop + hitHeight {
                    return task.id
                }
            case .surface:
                continue
            }
        }

        return nil
    }

    private func recenterToNow(proxy: ScrollViewProxy, nowAnchorUnitY: CGFloat) {
        commitDraftPoint()
        commitTitleEdit()
        editingTaskID = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("now-anchor", anchor: UnitPoint(x: 0.5, y: nowAnchorUnitY))
        }
        DispatchQueue.main.async {
            proxy.scrollTo("now-anchor", anchor: UnitPoint(x: 0.5, y: nowAnchorUnitY))
        }
    }

    private func resetRecenterTapState() {
        // Legacy no-op: recenter now uses system double-tap recognition.
    }

    private func handleGlobalRecenterDoubleTap(
        proxy: ScrollViewProxy,
        nowAnchorUnitY: CGFloat
    ) {
        if draftQuickCreate != nil || editingTitleTaskID != nil || isCommittingDraftPoint {
            return
        }
        recenterToNow(proxy: proxy, nowAnchorUnitY: nowAnchorUnitY)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale
    }

    private func viewportY(from location: CGPoint, in geo: GeometryProxy) -> CGFloat {
        let globalY = geo.frame(in: .global).minY + location.y
        return globalY - viewportGlobalMinYState
    }

    private var draftTitleBinding: Binding<String> {
        Binding(
            get: { draftQuickCreate?.title ?? "" },
            set: { newValue in
                guard draftQuickCreate != nil else { return }
                draftQuickCreate?.title = newValue
            }
        )
    }
    private func maybeExpandPastIfNeeded(
        topSentinelGlobalY: CGFloat,
        viewportGlobalMinY: CGFloat
    ) {
        guard topSentinelGlobalY.isFinite else { return }
        let distance = topSentinelGlobalY - viewportGlobalMinY

        // Re-arm when the over-pull is released back to the edge/content.
        if distance < boundaryPullReset {
            canExpandPast = true
        }

        // Two-step boundary: first over-pull arms, second over-pull loads.
        guard canExpandPast, distance > boundaryPullTrigger else { return }
        canExpandPast = false
        guard pastBoundaryPrimed else {
            pastBoundaryPrimed = true
            return
        }
        pastBoundaryPrimed = false
        expandPastWeekIfNeeded()
    }

    private func maybeExpandFutureIfNeeded(
        bottomSentinelGlobalY: CGFloat,
        viewportGlobalMaxY: CGFloat
    ) {
        guard bottomSentinelGlobalY.isFinite else { return }
        let distance = bottomSentinelGlobalY - viewportGlobalMaxY

        // Re-arm when the over-pull is released back to the edge/content.
        if distance > -boundaryPullReset {
            canExpandFuture = true
        }

        // Two-step boundary: first over-pull arms, second over-pull loads.
        guard canExpandFuture, distance < -boundaryPullTrigger else { return }
        canExpandFuture = false
        guard futureBoundaryPrimed else {
            futureBoundaryPrimed = true
            return
        }
        futureBoundaryPrimed = false
        expandFutureWeekIfNeeded()
    }

    private func expandPastWeekIfNeeded() {
        guard didInitialScroll, !isExpandingPast else { return }
        isExpandingPast = true
        loadedDaysPast += weekChunkDays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isExpandingPast = false
        }
    }

    private func expandFutureWeekIfNeeded() {
        guard didInitialScroll, !isExpandingFuture else { return }
        isExpandingFuture = true
        loadedDaysFuture += weekChunkDays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isExpandingFuture = false
        }
    }

    private func movingDateColumn(
        viewportHeight: CGFloat,
        viewportGlobalMinY: CGFloat,
        safeTopInset: CGFloat,
        safeBottomInset: CGFloat
    ) -> some View {
        let maskWidth = max(viewportWidth, 1)
        let anchorY = dateColumnAnchorY(
            viewportHeight: viewportHeight,
            safeTopInset: safeTopInset,
            safeBottomInset: safeBottomInset
        )
        let splitY = dateColumnColorSplitY(
            viewportHeight: viewportHeight,
            safeTopInset: safeTopInset,
            fallbackAnchorY: anchorY
        )
        let positions = dateColumnPositions(
            viewportHeight: viewportHeight,
            viewportGlobalMinY: viewportGlobalMinY,
            anchorY: anchorY
        )
        let currentY = positions.currentY
        let cycle = positions.cycle
        let baseDayIndex = positions.baseDayIndex

        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { offset in
                let index = baseDayIndex + offset
                if index >= 0 && index < totalDays {
                    dateColumnLabel(
                        for: dateForDay(index),
                        y: currentY + CGFloat(offset) * cycle,
                        viewportHeight: viewportHeight,
                        splitY: splitY
                    )
                }
            }
        }
        .frame(width: maskWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private func movingDateColumnTextMask(
        viewportHeight: CGFloat,
        viewportGlobalMinY: CGFloat,
        safeTopInset: CGFloat,
        safeBottomInset: CGFloat
    ) -> some View {
        let maskWidth = max(viewportWidth, 1)
        let anchorY = dateColumnAnchorY(
            viewportHeight: viewportHeight,
            safeTopInset: safeTopInset,
            safeBottomInset: safeBottomInset
        )
        let positions = dateColumnPositions(
            viewportHeight: viewportHeight,
            viewportGlobalMinY: viewportGlobalMinY,
            anchorY: anchorY
        )
        let currentY = positions.currentY
        let cycle = positions.cycle
        let baseDayIndex = positions.baseDayIndex

        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { offset in
                let index = baseDayIndex + offset
                if index >= 0 && index < totalDays {
                    dateColumnMaskLabelText(
                        for: dateForDay(index),
                        y: currentY + CGFloat(offset) * cycle,
                        viewportHeight: viewportHeight
                    )
                }
            }
        }
        .frame(width: maskWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private func dateColumnLabel(for date: Date, y: CGFloat, viewportHeight: CGFloat, splitY: CGFloat) -> some View {
        let maskWidth = max(viewportWidth, 1)
        let pastColor = timelineGray
        let futureColor = inkColor
        let clampedSplitY = min(max(splitY, 0), viewportHeight)

        return ZStack {
            let topHeight = max(0, clampedSplitY)
            let bottomHeight = max(0, viewportHeight - clampedSplitY)

            dateColumnLabelText(for: date, y: y, color: pastColor, viewportHeight: viewportHeight)
                .mask(
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: maskWidth, height: topHeight)
                        .frame(width: maskWidth, height: viewportHeight, alignment: .top)
                )

            dateColumnLabelText(for: date, y: y, color: futureColor, viewportHeight: viewportHeight)
                .mask(
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: maskWidth, height: bottomHeight)
                        .frame(width: maskWidth, height: viewportHeight, alignment: .bottom)
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func deleteSwipeGesture(for taskID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > deleteSwipeThreshold, abs(dx) > abs(dy) else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                store.deleteTask(taskID)
                if editingTaskID == taskID {
                    editingTaskID = nil
                }
                if editingTitleTaskID == taskID {
                    editingTitleTaskID = nil
                    editingTitleText = ""
                }
            }
    }

    private func activateTimelineEditMode(for taskID: UUID) {
        guard canEditOnTimeline else { return }
        guard editingTaskID != taskID else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        editingTaskID = taskID
    }

    private func restartEditPulseAnimation() {
        guard editingTaskID != nil else { return }
        editPulseOn = false
        DispatchQueue.main.async {
            guard editingTaskID != nil else { return }
            withAnimation(.easeInOut(duration: 0.68).repeatForever(autoreverses: true)) {
                editPulseOn = true
            }
        }
    }

    private func titleEditField(color: Color, fontSize: CGFloat = 15) -> some View {
        TextField("", text: $editingTitleText)
            .focused($isTitleInputFocused)
            .font(.system(size: fontSize, weight: .regular, design: .default))
            .foregroundStyle(color)
            .tint(inkColor)
            .textFieldStyle(.plain)
            .submitLabel(.done)
            .onSubmit {
                commitTitleEdit()
            }
    }

    private func dateColumnAnchorY(
        viewportHeight: CGFloat,
        safeTopInset: CGFloat,
        safeBottomInset: CGFloat
    ) -> CGFloat {
        let visibleHeight = max(0, viewportHeight - safeTopInset - safeBottomInset)
        let visibleCenterY = safeTopInset + visibleHeight * 0.5
        return min(max(visibleCenterY, 0), viewportHeight)
    }

    private func dateColumnColorSplitY(
        viewportHeight: CGFloat,
        safeTopInset: CGFloat,
        fallbackAnchorY: CGFloat
    ) -> CGFloat {
        if nowAnchorYInViewport.isFinite {
            return min(max(nowAnchorYInViewport + safeTopInset, 0), viewportHeight)
        }
        return min(max(fallbackAnchorY, 0), viewportHeight)
    }

    @ViewBuilder
    private func activeTopFadeMask(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        switch topMaskMode {
        case .hidden:
            Rectangle()
                .fill(Color.white)
                .frame(width: max(viewportWidth, 1), height: max(viewportHeight, 1), alignment: .topLeading)
        case .initialFullWidth:
            initialFullWidthTopFadeMask(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        case .tuned:
            fullWidthTopFadeMask(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }
    }

    private func initialFullWidthTopFadeMask(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.45), location: 0.08),
                .init(color: .white, location: 0.24),
                .init(color: .white, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: max(viewportWidth, 1), height: max(viewportHeight, 1), alignment: .topLeading)
    }

    private func fullWidthTopFadeMask(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let fullHeight = max(viewportHeight, 1)
        let maskHeight = max(fullHeight * 0.08, 1)

        return VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .white.opacity(0.10), location: 4.0 / 7.0),
                    .init(color: .white.opacity(0.10), location: 4.5 / 7.0),
                    .init(color: .white.opacity(0.50), location: 5.0 / 7.0),
                    .init(color: .white, location: 6.0 / 7.0),
                    .init(color: .white, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: maskHeight)

            Rectangle()
                .fill(Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: max(viewportWidth, 1), height: fullHeight, alignment: .topLeading)
    }

    private func dateColumnPositions(
        viewportHeight: CGFloat,
        viewportGlobalMinY: CGFloat,
        anchorY: CGFloat
    ) -> (baseDayIndex: Int, currentY: CGFloat, cycle: CGFloat) {
        let contentMinYInViewport: CGFloat
        if nowAnchorYInViewport.isFinite {
            contentMinYInViewport = nowAnchorYInViewport - yPosition(for: nowTime)
        } else {
            let source = scrollContentGlobalMinY.isFinite ? scrollContentGlobalMinY : smoothedContentMinY
            contentMinYInViewport = source.isFinite ? (source - viewportGlobalMinY) : 0
        }
        let topContentY = min(max(-contentMinYInViewport, 0), max(0, totalHeight - 1))
        let noonOffsetY = dateLabelAnchorHour * hourHeight
        // Rule: when date label sits at anchorY, the timeline time at anchorY is 12:00.
        let anchorContentY = min(max(topContentY + anchorY, 0), max(0, totalHeight - 1))
        let shiftedAnchorContentY = min(max(anchorContentY - noonOffsetY, 0), max(0, totalHeight - 1))
        let dayFloat = shiftedAnchorContentY / dayHeight
        let baseDayIndex = Int(floor(dayFloat))
        let dayProgress = dayFloat - floor(dayFloat)
        // One full 24-hour day maps to one full column travel.
        // Tighten adjacent date labels slightly so one full date/day stays visible.
        let cycle = max(1, viewportHeight - dateColumnLabelGapTighten)
        let currentY = anchorY - cycle * dayProgress
        return (baseDayIndex, currentY, cycle)
    }

    private func dateColumnLabelText(for date: Date, y: CGFloat, color: Color, viewportHeight: CGFloat) -> some View {
        let maskWidth = max(viewportWidth, 1)
        return Text(dayLabel(for: date))
            .font(.system(size: timelineFontSize, weight: .regular, design: .default))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .rotationEffect(.degrees(-90))
            .position(x: dateColumnLabelX, y: y)
            .frame(width: maskWidth, height: viewportHeight, alignment: .topLeading)
    }

    private func dateColumnMaskLabelText(for date: Date, y: CGFloat, viewportHeight: CGFloat) -> some View {
        let maskWidth = max(viewportWidth, 1)
        return Text(dayLabel(for: date))
            .font(.system(size: timelineFontSize, weight: .regular, design: .default))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .rotationEffect(.degrees(-90))
            .position(x: dateColumnLabelX, y: y)
            .frame(width: maskWidth, height: viewportHeight, alignment: .topLeading)
    }

    private func snappedMinutes(from translationY: CGFloat) -> Int {
        let rawMinutes = translationY / hourHeight * 60
        let snapped = Int((rawMinutes / Double(max(1, timelineSnapMinutes))).rounded()) * timelineSnapMinutes
        return snapped
    }

    private func dateForDay(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index, to: startDay) ?? startDay
    }

    private func dayLabel(for date: Date) -> String {
        Self.dayLabelFormatter.string(from: date)
    }

    private func dateAtViewportY(_ viewportY: CGFloat) -> Date {
        if let date = dateAtViewportYFromNowAnchor(viewportY) {
            return date
        }
        return dateAtViewportYFromContentOffset(viewportY)
    }

    private func dateAtViewportYFromContentOffset(_ viewportY: CGFloat) -> Date {
        let source = scrollContentGlobalMinY.isFinite ? scrollContentGlobalMinY : smoothedContentMinY
        guard source.isFinite else {
            return dateAtViewportYFromNowAnchor(viewportY) ?? nowTime
        }
        let contentMinYInViewport = source - viewportGlobalMinYState
        guard contentMinYInViewport.isFinite else {
            return dateAtViewportYFromNowAnchor(viewportY) ?? nowTime
        }
        let contentY = viewportY - contentMinYInViewport
        return dateFrom(y: contentY, totalHeight: totalHeight)
    }

    private func dateAtViewportYFromNowAnchor(_ viewportY: CGFloat) -> Date? {
        guard nowAnchorYInViewport.isFinite else { return nil }
        let deltaY = viewportY - nowAnchorYInViewport
        let deltaMinutes = deltaY / hourHeight * 60
        return nowTime.addingTimeInterval(TimeInterval(deltaMinutes * 60))
    }

    private func yPosition(for date: Date) -> CGFloat {
        let diff = date.timeIntervalSince(startDay)
        return CGFloat(diff / 3600) * hourHeight
    }

    private func dateFrom(y: CGFloat, totalHeight: CGFloat) -> Date {
        let clamped = min(max(0, y), totalHeight)
        let minutes = clamped / hourHeight * 60
        return startDay.addingTimeInterval(TimeInterval(minutes * 60))
    }
}

private struct DraftQuickCreate {
    var date: Date
    var title: String
}

private struct NowAnchorYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollContentGlobalMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TopSentinelGlobalYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BottomSentinelGlobalYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private final class ShakeDetector: ObservableObject {
    @Published var shakeToken: UUID?

    private let motionManager = CMMotionManager()
    private var lastShakeAt: Date = .distantPast
    private var candidateShakeAt: Date = .distantPast
    private var isRunning = false
    private let cooldown: TimeInterval = 1.6
    private let threshold: Double = 1.65
    private let pairWindow: TimeInterval = 0.35

    func start() {
        guard !isRunning else { return }
        guard motionManager.isAccelerometerAvailable else { return }
        isRunning = true
        motionManager.accelerometerUpdateInterval = 1.0 / 45.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let deltaFromGravity = abs(magnitude - 1.0)
            let now = Date()
            if deltaFromGravity > self.threshold {
                // Require two close spikes to avoid accidental triggers when placing phone on table.
                if now.timeIntervalSince(self.candidateShakeAt) <= self.pairWindow {
                    guard now.timeIntervalSince(self.lastShakeAt) > self.cooldown else { return }
                    self.lastShakeAt = now
                    self.candidateShakeAt = .distantPast
                    self.shakeToken = UUID()
                } else {
                    self.candidateShakeAt = now
                }
            } else if now.timeIntervalSince(self.candidateShakeAt) > self.pairWindow {
                self.candidateShakeAt = .distantPast
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        motionManager.stopAccelerometerUpdates()
        isRunning = false
    }
}

#if false
#Preview {
    TimelineScreen(
        store: LumosStore(),
        openTaskDetailAt: { _ in },
        openTaskDetailForTask: { _ in },
        openFocus: {}
    )
}
#endif
