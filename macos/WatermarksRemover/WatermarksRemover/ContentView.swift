import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Workspace: String, CaseIterable, Identifiable {
    case text = "Text"
    case files = "Files"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var service: ServiceModel
    @State private var workspace: Workspace? = .text
    @State private var source = ""
    @State private var cleanedText = ""
    @State private var findings = ""
    @State private var fileURL: URL?
    @State private var cleanedFile: Data?
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(Workspace.allCases, selection: $workspace) { item in
                Label(item.rawValue, systemImage: item == .text ? "text.alignleft" : "doc")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                statusBar
                Divider()
                if workspace == .files {
                    fileWorkspace
                } else {
                    textWorkspace
                }
            }
        }
        .navigationTitle("Watermarks Remover")
        .task { await service.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            service.stopServiceIfStarted()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(service.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(service.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let repo = service.repoPath {
                Text((repo as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("Choose Folder") { service.chooseRepo() }
            Button("Reconnect") { Task { await service.refresh() } }
                .disabled(service.busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var textWorkspace: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                editorHeader("Source", actions: {
                    Button("Sample") { source = "Hello\u{200B}world\u{00AD}." }
                    Button("Inspect") { Task { await inspectText() } }
                        .disabled(service.busy || source.isEmpty)
                    Button("Clean") { Task { await cleanText() } }
                        .disabled(service.busy || source.isEmpty)
                        .keyboardShortcut(.defaultAction)
                })
                TextEditor(text: $source)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 8) {
                editorHeader("Result", actions: {
                    Button("Copy") { copy(cleanedText.isEmpty ? findings : cleanedText) }
                        .disabled(cleanedText.isEmpty && findings.isEmpty)
                })
                TextEditor(text: resultBinding)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
        }
    }

    private var fileWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            HStack {
                Button("Open…") { openFile() }
                Button("Inspect") { Task { await inspectFile() } }
                    .disabled(service.busy || fileURL == nil)
                Button("Clean") { Task { await cleanFile() } }
                    .disabled(service.busy || fileURL == nil)
                    .keyboardShortcut(.defaultAction)
                Button("Save Cleaned…") { saveCleaned() }
                    .disabled(cleanedFile == nil)
                Spacer()
            }
            TextEditor(text: resultBinding)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            Text("For text and files you own.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var dropZone: some View {
        let name = fileURL?.lastPathComponent ?? "Drop a file here"
        return RoundedRectangle(cornerRadius: 10)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title2)
                    Text(name)
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        fileURL = url
                        cleanedFile = nil
                        findings = url.lastPathComponent
                    }
                }
                return true
            }
    }

    private var resultBinding: Binding<String> {
        Binding(get: { resultText }, set: { _ in })
    }

    private var resultText: String {
        if let error = service.lastError, findings.isEmpty, cleanedText.isEmpty {
            return error
        }
        var parts: [String] = []
        if !findings.isEmpty { parts.append(findings) }
        if !cleanedText.isEmpty { parts.append(cleanedText) }
        if let error = service.lastError { parts.append(error) }
        return parts.joined(separator: "\n\n")
    }

    private func editorHeader(_ title: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            actions()
        }
    }

    private func inspectText() async {
        guard let result = await service.inspect(data: Data(source.utf8), name: "note.txt") else { return }
        cleanedText = ""
        findings = Self.describe(result)
    }

    private func cleanText() async {
        guard let result = await service.clean(data: Data(source.utf8), name: "note.txt") else { return }
        cleanedText = String(decoding: result.data, as: UTF8.self)
        findings = result.summary
    }

    private func inspectFile() async {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let result = await service.inspect(data: data, name: fileURL.lastPathComponent) else { return }
        findings = Self.describe(result)
    }

    private func cleanFile() async {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let result = await service.clean(data: data, name: fileURL.lastPathComponent) else { return }
        cleanedFile = result.data
        findings = result.summary
        if result.kind == "text" || result.kind == "container",
           let text = String(data: result.data, encoding: .utf8) {
            cleanedText = text
        } else {
            cleanedText = ""
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                fileURL = url
                cleanedFile = nil
                findings = ""
                cleanedText = ""
            }
        }
    }

    private func saveCleaned() {
        guard let cleanedFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.cleanedName(fileURL?.lastPathComponent ?? "cleaned.bin")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? cleanedFile.write(to: url)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func describe(_ result: InspectResult) -> String {
        var lines = ["Kind: \(result.kind)"]
        if let suspicious = result.suspicious {
            lines.append(suspicious.verdict ? "Marks found." : "No marks reported.")
            for (name, item) in suspicious.classes.sorted(by: { $0.key < $1.key }) where item.present {
                lines.append("\(name.replacingOccurrences(of: "_", with: " ")) (\(item.strength)): \(item.summary)")
            }
        }
        if !result.detail.isEmpty {
            lines.append(result.detail)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanedName(_ name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        if ext.isEmpty { return "\(name).cleaned" }
        return "\(base).cleaned.\(ext)"
    }
}
