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
            .navigationDestination(for: Track.self) { TrackDetail(track: $0) }
        }
    }
}

struct TrackDetail: View {
    let track: Track

    private static let flags: [(Color, String, String)] = [
        (.green, "Green", "Track is clear. Go."),
        (.yellow, "Yellow", "Danger ahead. Slow down, no overtaking, be ready to stop."),
        (.red, "Red", "Session stopped. Slow down, stop safely if told to, and return to the pits slowly."),
        (.blue, "Blue", "A faster car is behind you. Hold your line and let it by."),
        (.black, "Black", "Come into the pits."),
        (.white, "Chequered", "Session over. Do one slow cool-down lap, then pit."),
    ]

    var body: some View {
        List {
            TrackMap(track: track)
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            Section("Before you drive") {
                ForEach(Self.flags, id: \.1) { color, name, meaning in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(name == "Chequered" ? AnyShapeStyle(LinearGradient(colors: [.white, .black, .white, .black], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(color))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: color == .black ? 1 : 0))
                            .frame(width: 22, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(name) flag").font(.subheadline.bold())
                            Text(meaning).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Label("Keep to the pit-lane speed limit, in and out.", systemImage: "gauge.with.dots.needle.33percent")
                Label("Your first laps are sighting laps: learn the track, don't push.", systemImage: "eye")
                Label("Tyres and brakes need a lap or two to warm up.", systemImage: "thermometer.medium")
                Label("Leave a big gap to the car in front.", systemImage: "arrow.left.and.right")
                Label("Check your mirrors before moving off the racing line.", systemImage: "car.rear")
            } header: {
                Text("Good habits")
            }
            if let corners = track.corners, !corners.isEmpty {
                Section("Corners") {
                    ForEach(corners, id: \.number) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Corner \(c.number)" + (c.name.map { " – \($0)" } ?? "")).font(.subheadline.bold())
                            if let note = c.note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(track.gates) { g in
                        Label(g.label, systemImage: g.isStartFinish ? "flag.checkered" : "flag")
                    }
                } header: {
                    Text("Timing lines")
                } footer: {
                    Text("Lap and sector times are taken as you cross these lines.")
                }
            }
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
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
    }
}
