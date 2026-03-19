import SwiftUI
import MapKit
import CoreData

struct LocationMapView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )
    @State private var annotations: [LocationAnnotation] = []
    @State private var selectedAnnotation: LocationAnnotation?
    @State private var selectedRange: QueryTimeRange = .lastWeek

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(coordinateRegion: $region, annotationItems: annotations) { ann in
                    MapAnnotation(coordinate: ann.coordinate) {
                        LocationPin(annotation: ann, isSelected: selectedAnnotation?.id == ann.id)
                            .onTapGesture { selectedAnnotation = ann }
                    }
                }
                .ignoresSafeArea(edges: .bottom)

                // Range picker overlay
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([QueryTimeRange.today, .lastWeek, .thisMonth, .all], id: \.label) { range in
                            FilterChip(title: range.label, isSelected: selectedRange.label == range.label) {
                                selectedRange = range
                                loadAnnotations()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            }
            .navigationTitle("位置地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(annotations.count) 个地点")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .sheet(item: $selectedAnnotation) { ann in
                LocationDetailSheet(annotation: ann)
            }
            .onAppear { loadAnnotations() }
        }
    }

    private func loadAnnotations() {
        let interval = selectedRange.interval
        let records = CDLocationRecord.fetch(from: interval.start, to: interval.end, in: context)

        let grouped = Dictionary(grouping: records) { r -> String in
            // Group by ~100m grid
            let lat = (r.latitude * 1000).rounded() / 1000
            let lon = (r.longitude * 1000).rounded() / 1000
            return "\(lat),\(lon)"
        }

        annotations = grouped.compactMap { _, records in
            guard let first = records.first, first.latitude != 0 else { return nil }
            return LocationAnnotation(
                id: first.id,
                coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                title: first.displayName,
                visitCount: records.count,
                lastVisit: records.map { $0.timestamp }.max() ?? first.timestamp
            )
        }

        // Center map on most recent location
        if let latest = annotations.max(by: { $0.lastVisit < $1.lastVisit }) {
            withAnimation {
                region.center = latest.coordinate
            }
        }
    }
}

// MARK: - Annotation Model

struct LocationAnnotation: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

// MARK: - Map Pin

struct LocationPin: View {
    let annotation: LocationAnnotation
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color("AccentPrimary") : Color("AccentPrimary").opacity(0.8))
                    .frame(width: isSelected ? 44 : 32, height: isSelected ? 44 : 32)
                    .shadow(radius: isSelected ? 6 : 3)

                Image(systemName: "mappin.fill")
                    .font(isSelected ? .body : .caption)
                    .foregroundColor(.white)
            }

            if annotation.visitCount > 1 {
                Text("\(annotation.visitCount)次")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color("AccentPrimary"))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .offset(y: -4)
            }
        }
        .animation(.spring(), value: isSelected)
    }
}

// MARK: - Detail Sheet

struct LocationDetailSheet: View {
    let annotation: LocationAnnotation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Mini map
                Map(coordinateRegion: .constant(MKCoordinateRegion(
                    center: annotation.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )), annotationItems: [annotation]) { ann in
                    MapMarker(coordinate: ann.coordinate, tint: Color("AccentPrimary"))
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Label(annotation.title.isEmpty ? "未知地点" : annotation.title,
                          systemImage: "mappin.circle.fill")
                        .font(.title3.bold())

                    HStack(spacing: 20) {
                        InfoBadge(icon: "repeat", value: "\(annotation.visitCount)次", label: "到访")
                        InfoBadge(icon: "clock", value: annotation.lastVisit.shortDateDisplay, label: "最近")
                        InfoBadge(icon: "location.fill",
                                  value: String(format: "%.4f", annotation.coordinate.latitude),
                                  label: "纬度")
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("地点详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct InfoBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(Color("AccentPrimary"))
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private extension Date {
    var shortDateDisplay: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        return fmt.string(from: self)
    }
}
