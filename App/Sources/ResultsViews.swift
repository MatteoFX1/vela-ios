import SwiftUI
import VelaCore

struct ResultsHeader: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.resultsTitle.capitalizedFirst).font(.system(size: 24, weight: .heavy))
                    Text("\(model.visibleResults.count) results").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                CircleIconButton(icon: model.detent == .full ? "chevron.down" : "chevron.up") {
                    withAnimation { model.detent = model.detent == .full ? .half : .full }
                }
                CircleIconButton(icon: "xmark") { withAnimation { model.clearSearch() } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "Open now", on: model.openNowOnly) { model.openNowOnly.toggle(); model.mapTick += 1 }
                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        FilterChipLabel(title: model.sort == .relevance ? "Sort" : model.sort.rawValue,
                                        on: model.sort != .relevance, menu: true)
                    }
                    FilterChip(title: "Rating 4.0+", on: model.rating4Only) { model.rating4Only.toggle(); model.mapTick += 1 }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

struct FilterChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { FilterChipLabel(title: title, on: on, menu: false) }.buttonStyle(.plain)
    }
}

struct FilterChipLabel: View {
    let title: String
    let on: Bool
    let menu: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if on && !menu { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            Text(title).font(.body.weight(.semibold))
            if menu { Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)) }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .foregroundColor(on ? Vela.onTonal(scheme) : .primary)
        .background(Capsule().fill(on ? Vela.tonal(scheme) : Color.clear))
        .overlay(Capsule().stroke(Color.secondary.opacity(on ? 0 : 0.5), lineWidth: 1))
    }
}

struct ResultsList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SheetTopMarker()
                LazyVStack(alignment: .leading, spacing: 0) {
                    Divider()
                    if model.visibleResults.isEmpty && !model.results.isEmpty {
                        // The filters hid everything: say so rather than show an empty list.
                        Text("Nothing here matches these filters. Turn one off to see more.")
                            .font(.body).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                            .padding(.vertical, 32).padding(.horizontal, 20)
                    }
                    ForEach(model.visibleResults) { p in
                        ResultRow(model: model, place: p)
                            .id(p.id)
                        Divider()
                    }
                }
                .padding(.bottom, 60)
            }
            .sheetScroll()
            .onReceive(NotificationCenter.default.publisher(for: DemoScript.scrollResults)) { _ in
                // Screenshot check only: scroll part way down the list.
                if let p = model.visibleResults.dropFirst(3).first {
                    withAnimation { proxy.scrollTo(p.id, anchor: .top) }
                }
            }
        }
    }
}

struct ResultRow: View {
    @ObservedObject var model: AppModel
    let place: Place
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name).font(.system(size: 20, weight: .bold)).foregroundColor(.primary)
            PlaceMetaLine(place: place, here: model.userLatLng)
            StatusText(place: place).font(.subheadline)
            if place.rating == nil, let a = place.address {
                Text(a).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            if !place.photoUrls.isEmpty {
                PhotoStrip(urls: place.photoUrls, height: 110).padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PillButton(title: "Directions", icon: "arrow.triangle.turn.up.right.diamond.fill", filled: true) {
                        model.selected = place
                        model.openDirections(to: place)
                    }
                    if let tel = telURL(place.phone) {
                        PillButton(title: "Call", icon: "phone.fill") { openURL(tel) }
                    }
                    if let web = webURL(place.website) {
                        PillButton(title: "Website", icon: "globe") { openURL(web) }
                    }
                    if let share = place.shareURL {
                        ShareLink(item: share) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.secondary.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { model.select(place) }
    }
}

struct PhotoStrip: View {
    let urls: [String]
    var height: CGFloat = 130
    /** Tapping a photo opens it full screen (on the place page; the result list opens the place). */
    var opensViewer = false
    /** Starts the strip with this place's Street View (or Look Around). */
    var streetView: Place?
    @State private var viewing: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let p = streetView { StreetViewTile(place: p, height: height) }
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    AsyncImage(url: URL(string: u)) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: height * 1.4, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { if opensViewer { viewing = i } }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            PhotoViewer(urls: urls, start: viewing ?? 0)
        }
    }
}

/** Photos full screen, swiped through, at a larger size than the strip asks for. */
struct PhotoViewer: View {
    let urls: [String]
    let start: Int
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    AsyncImage(url: URL(string: Self.large(u))) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFit()
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(Color.white.opacity(0.2)))
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .onAppear { page = start }
    }

    /** Google photo links carry their size ("=w408-h306-k-no"): ask for a bigger one. */
    static func large(_ u: String) -> String {
        guard let r = u.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return u }
        return u.replacingCharacters(in: r, with: "=w1600-h1200")
    }
}

func telURL(_ phone: String?) -> URL? {
    guard let phone else { return nil }
    return URL(string: "tel:" + phone.filter { "+0123456789".contains($0) })
}

func webURL(_ site: String?) -> URL? {
    guard let site else { return nil }
    return URL(string: site.hasPrefix("http") ? site : "https://" + site)
}
