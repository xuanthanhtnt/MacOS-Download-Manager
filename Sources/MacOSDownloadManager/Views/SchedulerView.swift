import SwiftUI

/// Queue manager & scheduler (IDM "Scheduler" window).
struct SchedulerView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var selection: UUID?
    @State private var newQueueName = ""

    init(initialSelection: UUID?) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                List(selection: $selection) {
                    ForEach(manager.queues) { queue in
                        HStack {
                            Image(systemName: manager.runningQueues.contains(queue.id) ? "play.circle.fill" : "list.bullet.rectangle")
                                .foregroundStyle(manager.runningQueues.contains(queue.id) ? Color.green : Color.secondary)
                            Text(verbatim: queue.displayName)
                        }
                        .tag(queue.id)
                    }
                }
                HStack {
                    TextField("New queue name", text: $newQueueName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addQueue)
                    Button {
                        addQueue()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(newQueueName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        if let id = selection { manager.removeQueue(id); selection = manager.mainQueue.id }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil || manager.queue(selection)?.isMain == true)
                }
                .padding([.horizontal, .bottom], 8)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            Group {
                if let id = selection, let queue = manager.queue(id) {
                    QueueEditor(queue: queue)
                        .id(queue.id)
                } else {
                    Text("Select a queue")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            if selection == nil { selection = manager.mainQueue.id }
        }
    }

    private func addQueue() {
        let name = newQueueName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        selection = manager.addQueue(named: name)
        newQueueName = ""
    }
}

private struct QueueEditor: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var queue: DownloadQueue
    @State private var tab = 0
    @State private var selectedFiles = Set<UUID>()

    init(queue: DownloadQueue) {
        _queue = State(initialValue: queue)
    }

    private var running: Bool { manager.runningQueues.contains(queue.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if queue.isMain {
                    Text(verbatim: queue.displayName).font(.title3.weight(.semibold))
                } else {
                    TextField("Queue name", text: $queue.name)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                }
                Spacer()
                if running {
                    Label("Running", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Button("Stop") { manager.stopQueue(queue.id) }
                } else {
                    Button("Start Now") { save(); manager.startQueue(queue.id) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            Picker("", selection: $tab) {
                Text("Schedule").tag(0)
                Text("Files in the queue").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == 0 {
                scheduleForm
            } else {
                filesList
            }
        }
        .padding(16)
        .onChange(of: queue) { _ in save() }
    }

    private func save() {
        manager.updateQueue(queue)
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<QueueSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = queue.schedule[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            queue.schedule[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    private var weekdaySymbols: [String] {
        Calendar.current.shortWeekdaySymbols
    }

    private var scheduleForm: some View {
        Form {
            Section {
                Stepper(value: $queue.maxConcurrent, in: 1...20) {
                    LabeledContent("Download files at the same time") {
                        Text(verbatim: "\(queue.maxConcurrent)").monospacedDigit()
                    }
                }
                Toggle("Start this queue when MacOS Download Manager starts", isOn: $queue.schedule.startOnLaunch)
            }
            Section("Start") {
                Toggle("Start the queue at", isOn: $queue.schedule.startEnabled)
                DatePicker("Time", selection: minutesBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                    .disabled(!queue.schedule.startEnabled)
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = queue.schedule.weekdays.contains(day)
                        Button {
                            if on {
                                queue.schedule.weekdays.removeAll { $0 == day }
                            } else {
                                queue.schedule.weekdays.append(day)
                                queue.schedule.weekdays.sort()
                            }
                        } label: {
                            Text(verbatim: weekdaySymbols[day - 1])
                                .font(.caption.weight(.semibold))
                                .frame(width: 40, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(!queue.schedule.startEnabled)
            }
            Section("Stop") {
                Toggle("Stop the queue at", isOn: $queue.schedule.stopEnabled)
                DatePicker("Time", selection: minutesBinding(\.stopMinutes), displayedComponents: .hourAndMinute)
                    .disabled(!queue.schedule.stopEnabled)
            }
            Section("When the queue has finished") {
                Picker("Then", selection: $queue.schedule.afterCompletion) {
                    ForEach(AfterQueueAction.allCases) { action in
                        Text(verbatim: action.title).tag(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var filesList: some View {
        let files = manager.itemsInQueue(queue.id)
        return VStack(alignment: .leading, spacing: 6) {
            List(selection: $selectedFiles) {
                ForEach(files) { item in
                    HStack {
                        Image(nsImage: FileIcon.icon(forExtension: item.fileExtension))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(verbatim: item.fileName).lineLimit(1)
                        Spacer()
                        Text(verbatim: item.status == .completed ? item.status.title : Fmt.percent(item.progress))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(item.id)
                }
            }
            .overlay {
                if files.isEmpty {
                    Text("No files. Use “Download Later” or right-click a download → Move to Queue.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            HStack {
                Button {
                    if let id = selectedFiles.first { manager.moveInQueue(id, up: true) }
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(selectedFiles.count != 1)
                Button {
                    if let id = selectedFiles.first { manager.moveInQueue(id, up: false) }
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(selectedFiles.count != 1)
                Spacer()
                Button("Remove from Queue") {
                    manager.move(selectedFiles, toQueue: nil)
                    selectedFiles.removeAll()
                }
                .disabled(selectedFiles.isEmpty)
            }
        }
    }
}

/// Countdown shown before quitting, sleeping or shutting down after a queue finishes.
struct CountdownView: View {
    let action: AfterQueueAction
    @State private var remaining = 30
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: action == .shutdown ? "power" : (action == .sleep ? "moon.fill" : "xmark.circle"))
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(verbatim: action.title)
                .font(.headline)
            Text(verbatim: String(format: NSLocalizedString("All downloads in the queue are finished. This happens in %d seconds.", comment: ""), remaining))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") {
                    timer?.invalidate()
                    WindowManager.shared.close("countdown")
                }
                .keyboardShortcut(.cancelAction)
                Button("Do It Now") { perform() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                DispatchQueue.main.async {
                    remaining -= 1
                    if remaining <= 0 { perform() }
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func perform() {
        timer?.invalidate()
        WindowManager.shared.close("countdown")
        switch action {
        case .none: break
        case .quitApp: AppDelegate.quitCompletely()
        case .sleep: SystemActions.sleepMac()
        case .shutdown:
            DownloadManager.shared.prepareForTermination()
            SystemActions.shutDownMac()
        }
    }
}
