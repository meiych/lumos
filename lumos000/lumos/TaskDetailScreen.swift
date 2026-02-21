import SwiftUI

struct TaskDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var store: LumosStore
    let presentation: TaskDetailPresentation

    @State private var editingTaskID: UUID?
    @State private var title: String
    @State private var note: String
    @State private var reminderEnabled: Bool
    @State private var reminderLead: Int
    @State private var focusEnabled: Bool
    @State private var repeatEnabled: Bool
    @State private var isEditingTitle: Bool

    @State private var taskStart: Date
    @State private var taskEnd: Date?
    @State private var taskType: TaskType

    @FocusState private var isTitleFieldFocused: Bool
    private let initialSeed: TaskDetailSeed

    private let titleHeaderHeight: CGFloat = 64
    private var canvasColor: Color { colorScheme == .dark ? .black : .white }
    private var inkColor: Color { colorScheme == .dark ? .white : .black }
    private var cardFillColor: Color { colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.035) }
    private var cardStrokeColor: Color { colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.84) }

    init(store: LumosStore, presentation: TaskDetailPresentation) {
        self.store = store
        self.presentation = presentation

        let seed = TaskDetailSeed.make(store: store, presentation: presentation)
        _editingTaskID = State(initialValue: seed.taskID)
        _title = State(initialValue: seed.title)
        _note = State(initialValue: seed.note)
        _reminderEnabled = State(initialValue: seed.reminderEnabled)
        _reminderLead = State(initialValue: seed.reminderLead)
        _focusEnabled = State(initialValue: seed.focusEnabled)
        _repeatEnabled = State(initialValue: false)
        _isEditingTitle = State(initialValue: seed.taskID == nil)
        _taskStart = State(initialValue: seed.startAt)
        _taskEnd = State(initialValue: seed.endAt)
        _taskType = State(initialValue: seed.type)
        self.initialSeed = seed
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle {
                        isEditingTitle = false
                        isTitleFieldFocused = false
                    }
                }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Spacer().frame(height: 116)

                    titleHeader

                    Text("任务详情编辑")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.66) : Color.black.opacity(0.45))

                    taskSettingsCard
                    actionsCard

                    Button(action: saveAndClose) {
                        Text("保存并关闭")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white : Color.black)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    Text("下滑也可保存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.34))
                        .padding(.bottom, 34)
                }
                .padding(.horizontal, 20)
            }
        }
        .background(canvasColor)
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard, edges: .all)
        .onAppear {
            if editingTaskID == nil {
                DispatchQueue.main.async {
                    isTitleFieldFocused = true
                }
            }
            normalizeRangeAfterTypeChange(taskType)
        }
        .onChange(of: taskType) { _, newValue in
            normalizeRangeAfterTypeChange(newValue)
        }
        .onChange(of: taskStart) { _, newValue in
            guard taskType != .point else {
                if taskEnd != nil {
                    taskEnd = newValue
                }
                return
            }
            if let end = taskEnd, end <= newValue {
                taskEnd = newValue.addingTimeInterval(5 * 60)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height

                    if isTitleFieldFocused {
                        isEditingTitle = false
                        isTitleFieldFocused = false
                        return
                    }

                    guard dy > 60, abs(dy) > abs(dx) * 1.3 else { return }
                    saveAndClose()
                }
        )
    }

    private var titleHeader: some View {
        ZStack {
            if isEditingTitle {
                TextField("", text: $title)
                    .font(.system(size: 48, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($isTitleFieldFocused)
                    .tint(inkColor)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        isEditingTitle = false
                        isTitleFieldFocused = false
                    }
            } else {
                Text(titleDisplay)
                    .font(.system(size: 48, weight: .semibold))
                    .multilineTextAlignment(.center)
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
        .frame(maxWidth: .infinity)
        .frame(height: titleHeaderHeight, alignment: .center)
        .padding(.top, 12)
        .transaction { tx in
            tx.animation = nil
        }
    }

    private var taskSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("任务设置")
                .font(.system(size: 17, weight: .semibold))

            Picker("任务类型", selection: $taskType) {
                Text("点").tag(TaskType.point)
                Text("线").tag(TaskType.line)
                Text("面").tag(TaskType.surface)
            }
            .pickerStyle(.segmented)

            dateRow(label: "开始", selection: $taskStart)

            if taskType != .point {
                dateRow(label: "结束", selection: endDateBinding)
            }

            Toggle("专注计时联动", isOn: $focusEnabled)
                .font(.system(size: 16, weight: .medium))

            Toggle("提醒", isOn: $reminderEnabled)
                .font(.system(size: 16, weight: .medium))

            if reminderEnabled {
                reminderLeadChips
            }

            TextField("备注", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 15))
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.78))
                )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: 1)
        )
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            Toggle("每日重复", isOn: $repeatEnabled)
                .font(.system(size: 16, weight: .medium))

            Button(role: .destructive) {
                deleteAndClose()
            } label: {
                Label("删除任务", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? Color.red.opacity(0.14) : Color.red.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: 1)
        )
    }

    private var reminderLeadChips: some View {
        HStack(spacing: 8) {
            ForEach([5, 10, 15, 30], id: \.self) { value in
                let selected = value == reminderLead
                Text("\(value) 分钟")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reminderChipForeground(selected: selected))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(reminderChipBackground(selected: selected))
                    )
                    .onTapGesture {
                        reminderLead = value
                    }
            }
            Spacer()
        }
    }

    private var endDateBinding: Binding<Date> {
        Binding<Date>(
            get: { taskEnd ?? taskStart.addingTimeInterval(60 * 60) },
            set: { newValue in
                let minEnd = taskStart.addingTimeInterval(5 * 60)
                taskEnd = max(newValue, minEnd)
            }
        )
    }

    private func reminderChipForeground(selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark ? .black : .white
        }
        return colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.64)
    }

    private func reminderChipBackground(selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark ? .white : .black
        }
        return colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private func dateRow(label: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.72))

            Spacer(minLength: 0)

            DatePicker(
                "",
                selection: selection,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(colorScheme == .dark ? .white : .black)
        }
    }

    private func normalizeRangeAfterTypeChange(_ type: TaskType) {
        if type == .point {
            if taskEnd != nil {
                taskEnd = taskStart
            }
            return
        }
        if taskEnd == nil || (taskEnd ?? taskStart) <= taskStart {
            taskEnd = taskStart.addingTimeInterval(5 * 60)
        }
    }

    private var titleDisplay: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名任务" : trimmed
    }

    private func saveAndClose() {
        let sanitizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = taskStart
        let rawEnd = taskEnd ?? taskStart
        let end = max(start, rawEnd)

        if editingTaskID == nil, !hasCreateEdits(sanitizedTitle: sanitizedTitle) {
            dismiss()
            return
        }

        var item: TaskItem
        if let id = editingTaskID, let existing = store.task(with: id) {
            item = existing
        } else {
            switch taskType {
            case .point:
                item = TaskItem.makePoint(at: start, title: sanitizedTitle)
            case .line:
                item = TaskItem.makeLine(
                    startAt: start,
                    endAt: end,
                    title: sanitizedTitle,
                    planDurationMinutes: max(5, Int(end.timeIntervalSince(start) / 60))
                )
            case .surface:
                item = TaskItem.makeSurface(startAt: start, endAt: end, title: sanitizedTitle)
            }
        }

        item.title = sanitizedTitle
        item.note = note
        item.focusEnabled = focusEnabled
        item.remindAt = reminderEnabled ? start.addingTimeInterval(Double(-reminderLead * 60)) : nil
        item.type = taskType
        item.startAt = start

        if taskType == .point {
            item.endAt = start
            item.planDurationMinutes = 0
        } else {
            let safeEnd = end > start ? end : start.addingTimeInterval(300)
            item.endAt = safeEnd
            item.planDurationMinutes = max(5, Int(safeEnd.timeIntervalSince(start) / 60))
        }

        store.upsertTask(item)

        if repeatEnabled {
            let nextStart = Calendar.current.date(byAdding: .day, value: 1, to: item.startAt) ?? item.startAt
            let nextEnd = item.endAt.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
            var repeated: TaskItem
            switch item.type {
            case .point:
                repeated = TaskItem.makePoint(at: nextStart, title: item.title)
            case .line:
                repeated = TaskItem.makeLine(
                    startAt: nextStart,
                    endAt: nextEnd,
                    title: item.title,
                    planDurationMinutes: item.planDurationMinutes
                )
            case .surface:
                repeated = TaskItem.makeSurface(
                    startAt: nextStart,
                    endAt: nextEnd ?? nextStart.addingTimeInterval(3600),
                    title: item.title
                )
            }
            repeated.note = item.note
            repeated.focusEnabled = item.focusEnabled
            repeated.remindAt = item.remindAt.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
            store.upsertTask(repeated)
        }

        dismiss()
    }

    private func hasCreateEdits(sanitizedTitle: String) -> Bool {
        if !sanitizedTitle.isEmpty { return true }
        if note.trimmingCharacters(in: .whitespacesAndNewlines) != initialSeed.note.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        if reminderEnabled != initialSeed.reminderEnabled { return true }
        if reminderLead != initialSeed.reminderLead { return true }
        if focusEnabled != initialSeed.focusEnabled { return true }
        if repeatEnabled { return true }
        if abs(taskStart.timeIntervalSince(initialSeed.startAt)) > 1 { return true }
        if taskType == .point && initialSeed.type == .point {
            let normalizedCurrentEnd = taskEnd ?? taskStart
            let normalizedInitialEnd = initialSeed.endAt ?? initialSeed.startAt
            if abs(normalizedCurrentEnd.timeIntervalSince(normalizedInitialEnd)) > 1 { return true }
        } else {
            switch (taskEnd, initialSeed.endAt) {
            case (nil, nil):
                break
            case let (lhs?, rhs?):
                if abs(lhs.timeIntervalSince(rhs)) > 1 { return true }
            default:
                return true
            }
        }
        if taskType != initialSeed.type { return true }
        return false
    }

    private func deleteAndClose() {
        if let id = editingTaskID {
            store.deleteTask(id)
        } else if case let .edit(taskID) = presentation {
            store.deleteTask(taskID)
        }
        dismiss()
    }
}

private struct TaskDetailSeed {
    var taskID: UUID?
    var title: String
    var note: String
    var reminderEnabled: Bool
    var reminderLead: Int
    var focusEnabled: Bool
    var startAt: Date
    var endAt: Date?
    var type: TaskType

    static func make(store: LumosStore, presentation: TaskDetailPresentation) -> TaskDetailSeed {
        switch presentation {
        case .create(let date):
            return TaskDetailSeed(
                taskID: nil,
                title: "",
                note: "",
                reminderEnabled: true,
                reminderLead: 5,
                focusEnabled: false,
                startAt: TaskScheduling.roundedToTenMinutes(date),
                endAt: nil,
                type: .point
            )
        case .edit(let taskID):
            guard let task = store.task(with: taskID) else {
                return make(store: store, presentation: .create(Date()))
            }
            let isPoint = task.type == .point
            return TaskDetailSeed(
                taskID: taskID,
                title: task.title,
                note: task.note,
                reminderEnabled: task.remindAt != nil,
                reminderLead: TaskScheduling.reminderLead(startAt: task.startAt, remindAt: task.remindAt),
                focusEnabled: task.focusEnabled,
                startAt: task.startAt,
                endAt: isPoint ? nil : task.endAt,
                type: task.type
            )
        }
    }
}

#if false
#Preview {
    NavigationStack {
        TaskDetailScreen(
            store: LumosStore(),
            presentation: .create(Date())
        )
    }
}
#endif
