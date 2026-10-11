import SwiftUI
import MapKit

struct TracksView: View {
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            List {
                if !TrackStore.shared.custom.isEmpty {
                    Section("Your tracks") {
                        ForEach(TrackStore.shared.custom) { t in
                            NavigationLink(value: t) { Text(t.name) }
                        }
                        .onDelete { idx in
                            idx.map { TrackStore.shared.custom[$0] }.forEach(TrackStore.shared.deleteCustom)
                            refresh += 1
                        }
                    }
                }
                Section("Built in") {
                    ForEach(TrackStore.shared.bundled) { t in
                        NavigationLink(value: t) { Text(t.name) }
                    }
                }
                Section {
                    Text("Tip: at a track that isn't listed, drive over the start line once and tap **Set start/finish here** on the Record tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .id(refresh)
            .navigationTitle("Tracks")
            .navigationDestination(for: Track.self) { TrackMap(track: $0) }
        }
    }
}

struct TrackMap: View {
    let track: Track
    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: track.center.lat, longitude: track.center.lon),
            latitudinalMeters: 1600, longitudinalMeters: 1600))) {
            ForEach(track.gates) { g in
                MapPolyline(coordinates: [
                    CLLocationCoordinate2D(latitude: g.start.lat, longitude: g.start.lon),
                    CLLocationCoordinate2D(latitude: g.end.lat, longitude: g.end.lon),
                ])
                .stroke(g.isStartFinish ? .orange : .cyan, lineWidth: 4)
                Annotation(g.label, coordinate: CLLocationCoordinate2D(latitude: g.start.lat, longitude: g.start.lon)) {
                    Circle().fill(g.isStartFinish ? .orange : .cyan).frame(width: 8, height: 8)
                }
            }
        }
        .mapStyle(.imagery)
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
