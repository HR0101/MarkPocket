import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var coordinator: SyncCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private var palette: MacPalette {
        MacPalette.resolve(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(coordinator.isSyncing ? palette.accent : (coordinator.settings.isAutoSyncEnabled ? palette.positive : palette.warning))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MarkPocket Sync")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text("\(coordinator.markdownSyncedCount) ファイル · \(coordinator.settings.isAutoSyncEnabled ? "監視中" : "停止中")")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.mutedText)
                }

                Spacer()

                Button {
                    coordinator.settings.isAutoSyncEnabled.toggle()
                } label: {
                    Text(coordinator.settings.isAutoSyncEnabled ? "停止" : "再開")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.syncNow() }
                } label: {
                    Text(coordinator.isSyncing ? "同期中" : "今すぐ同期")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.accentTextOnFill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isSyncing)

                Button {
                    coordinator.pickFoldersAndFiles()
                } label: {
                    Text("追加")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if !coordinator.syncedFiles.isEmpty {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("最近の同期")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.mutedText)
                        .padding(.bottom, 2)

                    ForEach(coordinator.syncedFiles.prefix(5)) { file in
                        Button {
                            coordinator.revealInFinder(file.destinationURL)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(palette.mutedText)
                                    .frame(width: 16)
                                Text(file.fileName)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                Spacer()
                                Text(file.sourceName)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(palette.mutedText)
                                    .lineLimit(1)
                            }
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            VStack(spacing: 4) {
                menuActionRow("管理ウィンドウを開く", icon: "macwindow") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }

                menuActionRow("Finder で iCloud フォルダを開く", icon: "folder") {
                    coordinator.openDestinationInFinder()
                }

                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 4)

                menuActionRow("終了", icon: "power", isDestructive: true) {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(palette.canvas)
    }

    private func menuActionRow(_ title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isDestructive ? palette.negative : palette.mutedText)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isDestructive ? palette.negative : palette.primaryText)
                Spacer()
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
