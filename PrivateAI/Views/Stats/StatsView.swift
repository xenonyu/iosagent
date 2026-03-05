import SwiftUI
import Charts

struct StatsView: View {
    @ObservedObject var viewModel: StatsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Range picker
                    rangePicker
                        .padding(.horizontal)

                    // Summary cards row
                    summaryCards
                        .padding(.horizontal)

                    // Health / Steps chart
                    if !viewModel.healthSummaries.isEmpty {
                        ChartCard(title: "每日步数", icon: "figure.walk") {
                            StepsChart(summaries: viewModel.healthSummaries)
                        }
                    }

                    // Sleep chart
                    if !viewModel.healthSummaries.isEmpty {
                        ChartCard(title: "睡眠时长（小时）", icon: "moon.zzz.fill") {
                            SleepChart(summaries: viewModel.healthSummaries)
                        }
                    }

                    // Mood chart
                    if !viewModel.moodData.isEmpty {
                        ChartCard(title: "心情分布", icon: "face.smiling") {
                            MoodChart(data: viewModel.moodData)
                        }
                    }

                    // Category breakdown
                    if !viewModel.categoryData.isEmpty {
                        ChartCard(title: "事件分类", icon: "list.bullet.rectangle") {
                            CategoryChart(data: viewModel.categoryData)
                        }
                    }

                    // Top locations
                    if !viewModel.locationData.isEmpty {
                        ChartCard(title: "常去地点", icon: "mappin.and.ellipse") {
                            LocationChart(data: viewModel.locationData)
                        }
                    }

                    // Photo activity
                    if !viewModel.photoActivityData.isEmpty {
                        ChartCard(title: "拍照活跃度", icon: "camera") {
                            PhotoActivityChart(data: viewModel.photoActivityData)
                        }
                    }

                    // Calendar events
                    if !viewModel.calendarEvents.isEmpty {
                        calendarEventsList
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("数据统计")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(
                    [QueryTimeRange.today, .lastWeek, .thisMonth, .lastMonth],
                    id: \.label
                ) { range in
                    FilterChip(
                        title: range.label,
                        isSelected: viewModel.selectedRange.label == range.label
                    ) {
                        viewModel.selectedRange = range
                    }
                }
            }
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            SummaryCard(
                icon: "figure.walk",
                color: .blue,
                title: "步数",
                value: viewModel.totalSteps.formatted(),
                unit: "步"
            )
            SummaryCard(
                icon: "flame.fill",
                color: .orange,
                title: "运动",
                value: "\(viewModel.totalExerciseMinutes)",
                unit: "分钟"
            )
            SummaryCard(
                icon: "moon.fill",
                color: .indigo,
                title: "平均睡眠",
                value: String(format: "%.1f", viewModel.avgSleepHours),
                unit: "小时"
            )
            if let mood = viewModel.dominantMood {
                SummaryCard(
                    icon: "face.smiling.fill",
                    color: .pink,
                    title: "主要心情",
                    value: mood.emoji,
                    unit: mood.label
                )
            }
        }
    }

    // MARK: - Calendar Events List

    private var calendarEventsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "calendar").foregroundColor(Color("AccentPrimary"))
                Text("日历事件").font(.headline)
                Spacer()
                Text("\(viewModel.calendarEvents.count) 个").foregroundColor(.secondary).font(.subheadline)
            }
            .padding()
            .background(Color(.systemBackground))

            Divider()

            ForEach(viewModel.calendarEvents.prefix(5)) { event in
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color("AccentPrimary"))
                        .frame(width: 4)
                        .clipShape(Capsule())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.subheadline).fontWeight(.medium)
                        Text(event.timeDisplay).font(.caption).foregroundColor(.secondary)
                        if !event.location.isEmpty {
                            Label(event.location, systemImage: "location.fill")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                if event.id != viewModel.calendarEvents.prefix(5).last?.id {
                    Divider().padding(.leading)
                }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .padding(.horizontal)
    }
}

// MARK: - Chart Card Container

struct ChartCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(Color("AccentPrimary"))
                Text(title).font(.headline)
            }
            content()
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .padding(.horizontal)
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                Spacer()
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - Steps Chart

struct StepsChart: View {
    let summaries: [HealthSummary]

    var body: some View {
        Chart(summaries, id: \.date) { summary in
            BarMark(
                x: .value("日期", summary.date, unit: .day),
                y: .value("步数", summary.steps)
            )
            .foregroundStyle(
                summary.steps >= 8000
                    ? Color("AccentPrimary")
                    : Color("AccentPrimary").opacity(0.5)
            )
            .cornerRadius(4)
        }
        .frame(height: 160)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("目标 8000步")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Sleep Chart

struct SleepChart: View {
    let summaries: [HealthSummary]

    var body: some View {
        Chart(summaries.filter { $0.sleepHours > 0 }, id: \.date) { summary in
            LineMark(
                x: .value("日期", summary.date, unit: .day),
                y: .value("睡眠", summary.sleepHours)
            )
            .foregroundStyle(Color.indigo)
            .interpolationMethod(.catmullRom)

            AreaMark(
                x: .value("日期", summary.date, unit: .day),
                y: .value("睡眠", summary.sleepHours)
            )
            .foregroundStyle(.linearGradient(
                colors: [.indigo.opacity(0.3), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.catmullRom)

            // Recommended line at 8h
            RuleMark(y: .value("推荐", 8))
                .lineStyle(StrokeStyle(dash: [4]))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .frame(height: 160)
        .chartYScale(domain: 0...12)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
    }
}

// MARK: - Mood Chart

struct MoodChart: View {
    let data: [MoodDataPoint]

    var body: some View {
        Chart(data) { point in
            BarMark(
                x: .value("日期", point.date, unit: .day),
                y: .value("次数", point.count)
            )
            .foregroundStyle(by: .value("心情", point.mood.label))
        }
        .frame(height: 140)
        .chartForegroundStyleScale([
            MoodType.great.label: Color.yellow,
            MoodType.good.label: Color.green,
            MoodType.neutral.label: Color.gray,
            MoodType.tired.label: Color.orange,
            MoodType.stressed.label: Color.red,
            MoodType.sad.label: Color.blue
        ])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

// MARK: - Category Chart

struct CategoryChart: View {
    let data: [CategoryDataPoint]

    var body: some View {
        Chart(data) { point in
            SectorMark(
                angle: .value("数量", point.count),
                innerRadius: .ratio(0.5),
                angularInset: 2
            )
            .foregroundStyle(by: .value("分类", point.category.label))
            .cornerRadius(4)
        }
        .frame(height: 180)
        .chartLegend(position: .trailing, alignment: .center)

        // Text labels below
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(data) { point in
                HStack(spacing: 4) {
                    Image(systemName: point.category.icon)
                        .font(.caption2)
                    Text("\(point.category.label) (\(point.count))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Location Chart

struct LocationChart: View {
    let data: [LocationDataPoint]

    var body: some View {
        Chart(data) { point in
            BarMark(
                x: .value("次数", point.visitCount),
                y: .value("地点", String(point.placeName.prefix(12)))
            )
            .foregroundStyle(Color("AccentPrimary").gradient)
            .cornerRadius(4)
        }
        .frame(height: max(CGFloat(data.count * 36), 120))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel()
            }
        }
    }
}

// MARK: - Photo Activity Chart

struct PhotoActivityChart: View {
    let data: [PhotoActivityPoint]

    var body: some View {
        Chart(data) { point in
            BarMark(
                x: .value("日期", point.date, unit: .day),
                y: .value("照片数", point.count)
            )
            .foregroundStyle(Color.pink.opacity(0.7))
            .cornerRadius(4)
        }
        .frame(height: 120)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
    }
}
