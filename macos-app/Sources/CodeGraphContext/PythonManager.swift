import Foundation
import os

/// Manages the lifecycle of the bundled Python CGC MCP server and visualization server.
@MainActor
final class PythonManager: ObservableObject {
    @Published var isMCPServerRunning = false
    @Published var isVizServerRunning = false
    @Published var isFalkorDBRunning = false

    private var falkorDBProcess: Process?
    private var mcpProcess: Process?
    private var vizProcess: Process?
    private var healthCheckTimer: Timer?
    private var mcpRestartCount = 0
    private var vizRestartCount = 0
    private let maxRestarts = 3

    private let logger = Logger(subsystem: "com.codegraphcontext.mac", category: "PythonManager")

    // MARK: - Configuration

    var mcpPort: Int = 47321
    var vizPort: Int = 47322
    let falkorDBPort = 6379

    /// Path to the bundled Python interpreter inside the app bundle.
    /// Falls back to system python3 during development.
    var pythonPath: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // Development fallback: use system python with cgc installed
        return "/usr/bin/env"
    }

    /// Whether we're using the bundled Python or a system fallback.
    var isBundled: Bool {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3").path {
            return FileManager.default.fileExists(atPath: bundled)
        }
        return false
    }

    // MARK: - FalkorDB Bundled Server

    /// Path to bundled redis-server binary (in app bundle or dev build)
    var redisServerPath: String? {
        // 1. App bundle
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("falkordb/redis-server").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2. Dev build directory (from bundle-falkordb.sh)
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/falkordb/redis-server").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        // 3. From falkordblite pip package (dev fallback)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pipPath = "\(home)/.pyenv/versions/3.12.4/lib/python3.12/site-packages/redislite/bin/redis-server"
        if FileManager.default.fileExists(atPath: pipPath) {
            return pipPath
        }
        return nil
    }

    /// Path to bundled falkordb.so module
    var falkorDBModulePath: String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("falkordb/falkordb.so").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/falkordb/falkordb.so").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pipPath = "\(home)/.pyenv/versions/3.12.4/lib/python3.12/site-packages/redislite/bin/falkordb.so"
        if FileManager.default.fileExists(atPath: pipPath) {
            return pipPath
        }
        return nil
    }

    /// Data directory for FalkorDB persistence
    var falkorDBDataDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CodeGraphContext/falkordb")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var falkorDBSocketPath: String {
        falkorDBDataDir.appendingPathComponent("falkordb.sock").path
    }

    // MARK: - Lifecycle

    func startAll() {
        startFalkorDB()
        startMCPServer()
        startVizServer()
        startHealthChecks()
    }

    func stopAll() {
        stopHealthChecks()
        stopMCPServer()
        stopVizServer()
        stopFalkorDB()
    }

    // MARK: - FalkorDB Server

    func startFalkorDB() {
        guard falkorDBProcess == nil else { return }
        guard let serverPath = redisServerPath, let modulePath = falkorDBModulePath else {
            logger.error("FalkorDB binaries not found. Run scripts/bundle-falkordb.sh first.")
            return
        }

        logger.info("Starting FalkorDB server...")

        // Remove stale socket
        try? FileManager.default.removeItem(atPath: falkorDBSocketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "--loadmodule", modulePath,
            "--unixsocket", falkorDBSocketPath,
            "--unixsocketperm", "700",
            "--port", String(falkorDBPort),
            "--dir", falkorDBDataDir.path,
            "--dbfilename", "dump.rdb",
            "--save", "900", "1",      // Save to disk every 15min if >=1 change
            "--save", "300", "100",    // Save every 5min if >=100 changes
            "--loglevel", "warning",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.logger.warning("FalkorDB exited with code \(proc.terminationStatus)")
                self?.falkorDBProcess = nil
                self?.isFalkorDBRunning = false
            }
        }

        do {
            try process.run()
            falkorDBProcess = process
            isFalkorDBRunning = true
            logger.info("FalkorDB started (PID \(process.processIdentifier))")

            // Wait for socket to appear
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: falkorDBSocketPath) {
                    logger.info("FalkorDB socket ready at \(self.falkorDBSocketPath)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            logger.error("FalkorDB socket did not appear within 20s")
        } catch {
            logger.error("Failed to start FalkorDB: \(error)")
        }
    }

    func stopFalkorDB() {
        guard let process = falkorDBProcess, process.isRunning else { return }
        logger.info("Stopping FalkorDB server")
        process.terminate()
        falkorDBProcess = nil
        isFalkorDBRunning = false
    }

    // MARK: - MCP Server

    func startMCPServer() {
        guard mcpProcess == nil else { return }
        logger.info("Starting MCP server on port \(self.mcpPort)")

        let process = Process()
        configureProcess(process)

        if isBundled {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-m", "codegraphcontext.cli.main", "mcp", "start",
                                 "--transport", "http", "--port", String(mcpPort)]
        } else {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["cgc", "mcp", "start",
                                 "--transport", "http", "--port", String(mcpPort)]
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.logger.info("MCP stdout: \(line)")
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.logger.error("MCP stderr: \(line)")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("MCP server exited with code \(proc.terminationStatus)")
                self.mcpProcess = nil
                self.isMCPServerRunning = false
                // Auto-restart on unexpected termination, with a cap
                if proc.terminationStatus != 0, self.mcpRestartCount < self.maxRestarts {
                    self.mcpRestartCount += 1
                    self.logger.info("Auto-restarting MCP server (attempt \(self.mcpRestartCount)/\(self.maxRestarts))...")
                    try? await Task.sleep(for: .seconds(2))
                    self.startMCPServer()
                } else if self.mcpRestartCount >= self.maxRestarts {
                    self.logger.error("MCP server failed after \(self.maxRestarts) restart attempts — giving up")
                }
            }
        }

        do {
            try process.run()
            mcpProcess = process
            isMCPServerRunning = true
            logger.info("MCP server started (PID \(process.processIdentifier))")
        } catch {
            logger.error("Failed to start MCP server: \(error)")
        }
    }

    func stopMCPServer() {
        guard let process = mcpProcess, process.isRunning else { return }
        logger.info("Stopping MCP server")
        process.terminate()
        mcpProcess = nil
        isMCPServerRunning = false
    }

    // MARK: - Visualization Server

    func startVizServer() {
        guard vizProcess == nil else { return }
        logger.info("Starting visualization server on port \(self.vizPort)")

        let process = Process()
        configureProcess(process)

        if isBundled {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-m", "codegraphcontext.cli.main", "visualize",
                                 "--port", String(vizPort), "--no-browser"]
        } else {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["cgc", "visualize",
                                 "--port", String(vizPort), "--no-browser"]
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.logger.info("Viz stdout: \(line)")
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.logger.error("Viz stderr: \(line)")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.vizProcess = nil
                self.isVizServerRunning = false
                if proc.terminationStatus != 0, self.vizRestartCount < self.maxRestarts {
                    self.vizRestartCount += 1
                    self.logger.info("Auto-restarting viz server (attempt \(self.vizRestartCount)/\(self.maxRestarts))...")
                    try? await Task.sleep(for: .seconds(2))
                    self.startVizServer()
                } else if self.vizRestartCount >= self.maxRestarts {
                    self.logger.error("Viz server failed after \(self.maxRestarts) restart attempts — giving up")
                }
            }
        }

        do {
            try process.run()
            vizProcess = process
            isVizServerRunning = true
            logger.info("Viz server started (PID \(process.processIdentifier))")
        } catch {
            logger.error("Failed to start viz server: \(error)")
        }
    }

    func stopVizServer() {
        guard let process = vizProcess, process.isRunning else { return }
        logger.info("Stopping visualization server")
        process.terminate()
        vizProcess = nil
        isVizServerRunning = false
    }

    // MARK: - Health Checks

    private func startHealthChecks() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkMCPHealth()
            }
        }
    }

    private func stopHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func checkMCPHealth() async {
        guard let url = URL(string: "http://localhost:\(mcpPort)/health") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if !isMCPServerRunning {
                    logger.info("MCP server health check passed — marking as running")
                    isMCPServerRunning = true
                }
            } else {
                logger.warning("MCP health check returned non-200")
                isMCPServerRunning = false
            }
        } catch {
            // Server not responding — may still be starting up
            if isMCPServerRunning {
                logger.warning("MCP health check failed: \(error)")
                isMCPServerRunning = false
            }
        }
    }

    // MARK: - Process Configuration

    private func configureProcess(_ process: Process) {
        var env = ProcessInfo.processInfo.environment
        // Database: connect to the bundled FalkorDB server via TCP
        env["CGC_RUNTIME_DB_TYPE"] = "falkordb-remote"
        env["FALKORDB_HOST"] = "localhost"
        env["FALKORDB_PORT"] = String(falkorDBPort)

        // In dev mode, GUI processes don't inherit the shell PATH.
        // Append common locations where pip/pyenv/Homebrew install binaries.
        if !isBundled {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let extraPaths = [
                "\(home)/.pyenv/shims",
                "\(home)/.pyenv/bin",
                "\(home)/.local/bin",
                "/usr/local/bin",
                "/opt/homebrew/bin",
            ]
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        }

        process.environment = env

        // Set working directory to app support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cgcDir = appSupport.appendingPathComponent("CodeGraphContext")
        try? FileManager.default.createDirectory(at: cgcDir, withIntermediateDirectories: true)
        process.currentDirectoryURL = cgcDir
    }
}
