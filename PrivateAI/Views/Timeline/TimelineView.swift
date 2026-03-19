import SwiftUI

struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    @State private var showMap = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                filterBar

                Divider()

                // Event list
                if viewModel.filteredEvents.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle("时光轴")
            .searchable(text: $viewModel.searchText, prompt: "搜索事件...")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showMap = true
                    } label: {
                        Image(systemName: "map.fill")
                            .foregroundColor(Color("AccentPrimary"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.showAddEvent = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Color("AccentPrimary"))
                    }
                }
            }
            .sheet(isPresented: $viewModel.showAddEvent) {
                AddEventSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showEditEvent) {
                EditEventSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showMap) {
                LocationMapView()
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            // Time range picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([QueryTimeRange.today, .lastWeek, .thisMonth, .all], id: \.label) { range in
                        FilterChip(
                            title: range.label,
                            isSelected: viewModel.selectedRange.label == range.label
                        ) {
                            viewModel.selectedRange = range
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "全部", isSelected: viewModel.selectedCategory == nil) {
                        viewModel.selectedCategory = nil
                    }
                    ForEach(EventCategory.allCases, id: \.rawValue) { cat in
                        FilterChip(
                            title: cat.label,
                            icon: cat.icon,
                            isSelected: viewModel.selectedCategory == cat
                        ) {
                            viewModel.selectedCategory = viewModel.selectedCategory == cat ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Event List

    private var eventList: some View {
        List {
            ForEach(groupedEvents.keys.sorted(by: >), id: \.self) { dateKey in
                Section {
                    ForEach(groupedEvents[dateKey] ?? []) { event in
                        EventRow(event: event)
                            .swipeActions(edge: .leading) {
                                Button {
                                    viewModel.beginEdit(event)
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteEvent(event)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(dateKey)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var groupedEvents: [String: [LifeEvent]] {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 EEEE"
        fmt.locale = Locale(identifier: "zh-Hans")
        return Dictionary(grouping: viewModel.filteredEvents) {
            fmt.string(from: $0.timestamp)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无记录")
                .font(.title2)
                .fontWeight(.semibold)

            Text("点击右上角 + 添加事件\n或者在聊天中告诉我你做了什么")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button {
                viewModel.showAddEvent = true
            } label: {
                Label("添加第一条记录", systemImage: "plus")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color("AccentPrimary"))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: LifeEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Mood emoji
            Text(event.mood.emoji)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Color(.systemGray6))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(event.timestamp.timeOnly)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !event.content.isEmpty && event.content != event.title {
                    Text(event.content)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Image(systemName: event.category.icon)
                        .font(.caption2)
                    Text(event.category.label)
                        .font(.caption)
                }
                .foregroundColor(Color("AccentPrimary"))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Event Sheet

struct AddEventSheet: View {
    @ObservedObject var viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("事件内容") {
                    TextField("发生了什么？", text: $viewModel.newEventTitle)
                    TextEditor(text: $viewModel.newEventContent)
                        .frame(minHeight: 80)
                        .overlay(
                            Group {
                                if viewModel.newEventContent.isEmpty {
                                    Text("详细描述（可选）")
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 4)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                }

                Section("心情") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(MoodType.allCases, id: \.rawValue) { mood in
                                MoodButton(mood: mood, isSelected: viewModel.newEventMood == mood) {
                                    viewModel.newEventMood = mood
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $viewModel.newEventCategory) {
                        ForEach(EventCategory.allCases, id: \.rawValue) { cat in
                            Label(cat.label, systemImage: cat.icon).tag(cat)
                        }
                    }
                }
            }
            .navigationTitle("添加事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.addEvent()
                        dismiss()
                    }
                    .disabled(viewModel.newEventTitle.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Edit Event Sheet

struct EditEventSheet: View {
    @ObservedObject var viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("事件内容") {
                    TextField("发生了什么？", text: $viewModel.newEventTitle)
                    TextEditor(text: $viewModel.newEventContent)
                        .frame(minHeight: 80)
                }
                Section("心情") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(MoodType.allCases, id: \.rawValue) { mood in
                                MoodButton(mood: mood, isSelected: viewModel.newEventMood == mood) {
                                    viewModel.newEventMood = mood
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("分类") {
                    Picker("分类", selection: $viewModel.newEventCategory) {
                        ForEach(EventCategory.allCases, id: \.rawValue) { cat in
                            Label(cat.label, systemImage: cat.icon).tag(cat)
                        }
                    }
                }
            }
            .navigationTitle("编辑事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.showEditEvent = false; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.updateEvent()
                        dismiss()
                    }
                    .disabled(viewModel.newEventTitle.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color("AccentPrimary") : Color(.systemGray6))
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mood Button

struct MoodButton: View {
    let mood: MoodType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(mood.emoji).font(.title2)
                Text(mood.label).font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color("AccentPrimary").opacity(0.15) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color("AccentPrimary"), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Date helper

private extension Date {
    var timeOnly: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: self)
    }
}
