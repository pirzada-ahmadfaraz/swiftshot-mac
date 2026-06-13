import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Capture History library window — a searchable grid of every screenshot,
/// video and GIF the app has captured. A normal titled window (not an overlay
/// panel) hosting a SwiftUI grid.
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    /// Filled by the integrator with `capture.openInEditor(_:)`. Given the full
    /// asset as a CGImage, opens it in the annotation editor. The grid only calls
    /// this for image items; everything else (copy/save/reveal/delete/drag) is
    /// handled directly via NSPasteboard/NSWorkspace and needs no shared access.
    var onOpenInEditor: ((CGImage) -> Void)?

    /// Broadcast when the window is (re)shown so the grid re-reads the store.
    static let didShowNotification = Notification.Name("HistoryWindowDidShow")

    private init() {}

    func show() {
        if let window {
            NotificationCenter.default.post(name: Self.didShowNotification, object: nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = HistoryGridView(
            onOpenInEditor: { [weak self] image in self?.onOpenInEditor?(image) }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Capture History"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View model

@MainActor
private final class HistoryViewModel: ObservableObject {
    @Published var query: String = "" { didSet { refresh() } }
    @Published private(set) var items: [HistoryItem] = []

    func refresh() {
        items = HistoryStore.shared.search(query)
    }
}

// MARK: - Grid

private struct HistoryGridView: View {
    let onOpenInEditor: (CGImage) -> Void
    @StateObject private var model = HistoryViewModel()

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search captures…", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.items) { item in
                            HistoryCell(item: item, onOpenInEditor: onOpenInEditor) {
                                model.refresh()
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryWindowController.didShowNotification)) { _ in
            model.refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "No captures yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("Screenshots and recordings you take will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cell

private struct HistoryCell: View {
    let item: HistoryItem
    let onOpenInEditor: (CGImage) -> Void
    let onChanged: () -> Void

    @State private var hovering = false

    private var assetURL: URL { HistoryStore.shared.assetURL(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(hovering ? 0.25 : 0.1), lineWidth: 1)
                    )
                if item.type != .image {
                    Image(systemName: item.type == .gif ? "square.stack.3d.up" : "play.circle.fill")
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }

            Text(item.sourceApp ?? item.filename)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(Self.dateString(item.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { openInEditor() }
        .onDrag { NSItemProvider(object: assetURL as NSURL) }
        .contextMenu {
            if item.type == .image {
                Button("Open in Editor") { openInEditor() }
            }
            Button("Copy") { copy() }
            Button("Save As…") { saveAs() }
            Button("Reveal in Finder") { reveal() }
            Divider()
            Button("Delete", role: .destructive) { delete() }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = NSImage(contentsOf: HistoryStore.shared.thumbnailURL(for: item)) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func openInEditor() {
        guard item.type == .image, let image = HistoryStore.shared.loadImage(for: item) else { return }
        onOpenInEditor(image)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.type == .image {
            if let data = try? Data(contentsOf: assetURL) {
                pb.setData(data, forType: .png)
            }
        } else {
            pb.writeObjects([assetURL as NSURL])
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        if let type = UTType(filenameExtension: (item.assetPath as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        let source = assetURL
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                Log.error("History: Save As failed: \(error)", log: Log.general)
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([assetURL])
    }

    private func delete() {
        HistoryStore.shared.delete(id: item.id)
        onChanged()
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
