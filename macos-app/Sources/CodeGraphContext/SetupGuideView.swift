import SwiftUI
import AppKit

struct SetupGuideView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var indexPath: String?
    @State private var indexStats: String?
    @State private var isIndexing = false
    @State private var pluginInstalled = false
    @State private var pluginError: String?

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            ProgressView(value: Double(step), total: Double(totalSteps - 1))
                .padding(.horizontal, 24)
                .padding(.top, 16)

            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: pluginStep
                case 2: indexStep
                case 3: tryItStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Text("Welcome to CodeGraphContext")
                .font(.title2.bold())

            Text("CodeGraphContext gives Claude Code structural understanding of your codebase. It parses your code into a graph database, then exposes query tools so Claude can answer questions like \"who calls this function?\" or \"find dead code\" in milliseconds.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    statBox("16", "Languages")
                    statBox("21", "MCP Tools")
                    statBox("6", "Node Types")
                }
                Text("Functions, Classes, Imports, Calls, Inheritance, Parameters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            navButtons(backLabel: nil, nextLabel: "Get Started")
        }
    }

    // MARK: - Step 1: Plugin

    private var pluginStep: some View {
        VStack(spacing: 16) {
            Text("Connect to Claude Code")
                .font(.title2.bold())

            Text("Install the plugin so Claude Code can use the graph tools.")
                .foregroundColor(.secondary)

            Spacer()

            if pluginInstalled {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    Text("Plugin installed")
                        .font(.headline)
                    Text("Restart Claude Code to activate.")
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    Button("Install Plugin") {
                        installPlugin()
                    }
                    .controlSize(.large)

                    if let error = pluginError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Text("Or install manually:")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.top, 8)
                    copiableCode("claude plugin install codegraphcontext")
                }
            }

            Spacer()

            navButtons(backLabel: "Back", nextLabel: pluginInstalled ? "Next" : "Skip")
        }
    }

    // MARK: - Step 2: Index

    private var indexStep: some View {
        VStack(spacing: 16) {
            Text("Index Your First Repository")
                .font(.title2.bold())

            Text("Select a git repository to index. This builds the code graph.")
                .foregroundColor(.secondary)

            Spacer()

            if isIndexing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Indexing \(indexPath?.components(separatedBy: "/").last ?? "")...")
                        .foregroundColor(.secondary)
                    if let phase = appState.indexingManager.indexingPhase {
                        Text(phase.replacingOccurrences(of: "_", with: " "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if let stats = indexStats {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    Text(stats)
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Select Repository...") {
                    selectAndIndex()
                }
                .controlSize(.large)
            }

            Spacer()

            navButtons(
                backLabel: "Back",
                nextLabel: indexStats != nil ? "Next" : "Skip",
                nextDisabled: isIndexing
            )
        }
    }

    // MARK: - Step 3: Try It

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try It Out")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Copy these prompts into Claude Code:")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            let prompts = [
                "Who calls the authenticate function?",
                "Find dead code in this project",
                "What would break if I changed the User model?",
                "Show me circular dependencies",
                "What are the most complex functions?",
            ]

            ForEach(prompts, id: \.self) { prompt in
                promptRow(prompt)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Components

    private func statBox(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 100)
    }

    private func copiableCode(_ text: String) -> some View {
        HStack {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func promptRow(_ prompt: String) -> some View {
        HStack {
            Text(prompt)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
        .padding(.vertical, 4)
    }

    private func navButtons(
        backLabel: String?,
        nextLabel: String,
        nextDisabled: Bool = false
    ) -> some View {
        HStack {
            if let back = backLabel {
                Button(back) { step -= 1 }
                    .controlSize(.large)
            }
            Spacer()
            Button(nextLabel) { step += 1 }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(nextDisabled)
        }
    }

    // MARK: - Plugin Installation

    private func installPlugin() {
        pluginError = nil
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // 1. Find the plugin source (bundled or dev)
        let devSource = "\(home)/git/CodeGraphContext/claude-plugin"
        let bundledSource = Bundle.main.resourceURL?.appendingPathComponent("claude-plugin").path

        guard let source = [bundledSource, devSource].compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0) }) else {
            pluginError = "Plugin source not found. Clone the CodeGraphContext repo first."
            return
        }

        // 2. Copy to Claude plugins cache
        let cacheDir = "\(home)/.claude/plugins/cache/DataToRag/codegraphcontext/1.0.0"
        do {
            if fm.fileExists(atPath: cacheDir) {
                try fm.removeItem(atPath: cacheDir)
            }
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

            // Copy .claude-plugin/
            let pluginDir = "\(source)/.claude-plugin"
            if fm.fileExists(atPath: pluginDir) {
                try fm.copyItem(atPath: pluginDir, toPath: "\(cacheDir)/.claude-plugin")
            }

            // Copy skills/
            let skillsDir = "\(source)/skills"
            if fm.fileExists(atPath: skillsDir) {
                try fm.copyItem(atPath: skillsDir, toPath: "\(cacheDir)/skills")
            }

            // Copy README
            let readme = "\(source)/README.md"
            if fm.fileExists(atPath: readme) {
                try fm.copyItem(atPath: readme, toPath: "\(cacheDir)/README.md")
            }
        } catch {
            pluginError = "Failed to copy plugin: \(error.localizedDescription)"
            return
        }

        // 3. Register in installed_plugins.json
        let installedPath = "\(home)/.claude/plugins/installed_plugins.json"
        do {
            var root: [String: Any] = ["version": 2, "plugins": [String: Any]()]
            if let data = fm.contents(atPath: installedPath),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = json
            }

            var plugins = root["plugins"] as? [String: Any] ?? [:]
            let key = "codegraphcontext@DataToRag"
            let now = ISO8601DateFormatter().string(from: Date())
            plugins[key] = [[
                "scope": "user",
                "installPath": cacheDir,
                "version": "1.0.0",
                "installedAt": now,
                "lastUpdated": now,
            ]]
            root["plugins"] = plugins

            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: installedPath))
        } catch {
            pluginError = "Plugin copied but failed to register: \(error.localizedDescription)"
            return
        }

        pluginInstalled = true
    }

    // MARK: - Actions

    private func selectAndIndex() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository to index"
        panel.prompt = "Index"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let error = IndexingManager.validateRepoPath(url.path) {
            let alert = NSAlert()
            alert.messageText = "Cannot Index Directory"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        indexPath = url.path
        isIndexing = true

        Task { @MainActor in
            await appState.indexingManager.indexRepository(at: url.path)
            isIndexing = false

            // Fetch stats
            if let stats = appState.indexingManager.graphStats {
                indexStats = "\(stats.files) files, \(stats.functions) functions, \(stats.classes) classes"
            } else {
                indexStats = "Indexing complete"
            }
        }
    }
}
