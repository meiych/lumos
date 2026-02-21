//
//  ContentView.swift
//  lumos
//
//  Created by epi on 2/7/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = LumosStore()
    @State private var taskDetailPresentation: TaskDetailPresentation?
    @State private var showFocus = false

    var body: some View {
        NavigationStack {
            TimelineScreen(
                store: store,
                openTaskDetailAt: { date in
                    taskDetailPresentation = .create(date)
                },
                openTaskDetailForTask: { taskID in
                    taskDetailPresentation = .edit(taskID)
                },
                openFocus: { showFocus = true }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $taskDetailPresentation) { presentation in
            TaskDetailScreen(
                store: store,
                presentation: presentation
            )
            .ignoresSafeArea()
            .ignoresSafeArea(.keyboard, edges: .all)
        }
        .fullScreenCover(isPresented: $showFocus) {
            FocusScreen(
                store: store,
                taskId: nil,
                close: { showFocus = false }
            )
            .ignoresSafeArea(.keyboard, edges: .all)
        }
        .onAppear {
            store.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .inactive || phase == .background else { return }
            Task {
                await store.flushSaves()
            }
        }
    }
}

enum TaskDetailPresentation: Identifiable, Equatable {
    case create(Date)
    case edit(UUID)

    var id: String {
        switch self {
        case .create(let date):
            return "create-\(date.timeIntervalSince1970)"
        case .edit(let taskID):
            return "edit-\(taskID.uuidString)"
        }
    }
}

#if false
#Preview {
    ContentView()
}
#endif
