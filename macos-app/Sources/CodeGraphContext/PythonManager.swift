import Foundation
import os

/// Manages the lifecycle of the bundled Python CGC MCP server and visualization server.
@MainActor
final class PythonManager: ObservableObject {
    @Published var isMCPServerRunning = false
    @Published var isVizServerRunning = false

    private var mcpProcess: Process?
    private var vizProcess: Process?
    private var healthCheckTimer: Timer?

    private let logger = Logger(subsystem: "com.codegraphcontext.mac", category: "PythonManager")

    // MARK: - Configuration

    var mcpPort: Int = 3100
    var vizPort: Int = 8000

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

    // MARK: - FalkorDB Configuration

    var falkorDBPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cgcDir = appSupport.appendingPathComponent("CodeGraphContext")
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: cgcDir, withIntermediateDirectories: true)
        return cgcDir.appendingPathComponent("falkordb.db").path
    }

    // MARK: - Lifecycle

    func startAll() {
        startMCPServer()
        startVizServer()
        startHealthChecks()
    }

    func stopAll() {
        stopHealthChecks()
        stopMCPServer()
        stopVizServer()
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
                self?.logger.warning("MCP server exited with code \(proc.terminationStatus)")
                self?.mcpProcess = nil
                self?.isMCPServerRunning = false
                // Auto-restart on unexpected termination
                if proc.terminationStatus != 0 {
                    self?.logger.info("Auto-restarting MCP server after crash...")
                    try? await Task.sleep(for: .seconds(2))
                    self?.startMCPServer()
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
                self?.vizProcess = nil
                self?.isVizServerRunning = false
                if proc.terminationStatus != 0 {
                    self?.logger.info("Auto-restarting viz server after crash...")
                    try? await Task.sleep(for: .seconds(2))
                    self?.startVizServer()
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
        // FalkorDB configuration
        env["CGC_RUNTIME_DB_TYPE"] = "falkordb"
        env["FALKORDB_PATH"] = falkorDBPath
        process.environment = env

        // Set working directory to app support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cgcDir = appSupport.appendingPathComponent("CodeGraphContext")
        try? FileManager.default.createDirectory(at: cgcDir, withIntermediateDirectories: true)
        process.currentDirectoryURL = cgcDir
    }
}
