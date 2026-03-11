// Plugin.swift — ChorographOpenCodeServerPlugin
// Entry point for the OpenCode Server Chorograph plugin.
// Registers the OpenCodeServerProvider as an AI provider and a settings panel.

import ChorographPluginSDK
import SwiftUI

public final class OpenCodeServerPlugin: ChorographPlugin, @unchecked Sendable {

    public let manifest = PluginManifest(
        id: "com.chorograph.plugin.opencode-server",
        displayName: "OpenCode Server",
        description: "Connects to a locally running opencode server via REST/SSE.",
        version: "1.0.0",
        capabilities: [.aiProvider, .settingsPanel]
    )

    public init() {}

    public func bootstrap(context: any PluginContextProviding) async throws {
        context.registerProvider(OpenCodeServerProvider())
        context.registerSettingsPanel(title: "OpenCode Server", AnyView(OpenCodeServerSettingsView()))
    }
}

// MARK: - C-ABI factory (required for dlopen-based loading)

@_cdecl("chorograph_plugin_create")
public func chorographPluginCreate() -> UnsafeMutableRawPointer {
    let plugin = OpenCodeServerPlugin()
    return Unmanaged.passRetained(plugin as AnyObject).toOpaque()
}
