import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopSlotSettingsView: View {
    @ObservedObject private var store = DesktopSlotStore.shared
    @State private var selectedSlotID: String?
    @State private var newSlotName = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var slots: [DesktopWallpaperSlot] {
        store.slots
    }

    private var selectedSlot: DesktopWallpaperSlot? {
        let id = selectedSlotID ?? slots.first?.id
        return id.flatMap { store.slot(id: $0) }
    }

    var body: some View {
        MacSettingsSection(header: "桌面槽位") {
            VStack(spacing: 0) {
                headerRow
                Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                if slots.isEmpty {
                    emptyRow
                } else {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        slotRow(slot: slot, index: index, isLast: index == slots.count - 1)
                    }
                }

                if let selectedSlot {
                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)
                    selectedSlotActions(slot: selectedSlot)
                }

                if let statusMessage {
                    messageRow(statusMessage, color: .green)
                }
                if let errorMessage {
                    messageRow(errorMessage, color: .red)
                }
            }
        }
        .onAppear {
            if selectedSlotID == nil {
                selectedSlotID = slots.first?.id
            }
            if let selectedSlot {
                newSlotName = selectedSlot.name
            }
        }
        .onReceive(store.$document) { _ in
            if selectedSlotID == nil || selectedSlotID.flatMap({ store.slot(id: $0) }) == nil {
                selectedSlotID = slots.first?.id
            }
            if let selectedSlot, newSlotName.isEmpty {
                newSlotName = selectedSlot.name
            }
        }
        .onChange(of: selectedSlotID) { _, _ in
            if let selectedSlot {
                newSlotName = selectedSlot.name
            }
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("WaifuX 桌面 1 / 桌面 2 是稳定槽位，不自动跟随 Mission Control 顺序。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.72))

                Spacer()

                Button {
                    createSlot()
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }

            Text("未绑定槽位设置壁纸会先保存为待应用；切到目标系统桌面后，点“绑定当前桌面并应用”。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.42))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyRow: some View {
        HStack {
            Text("还没有桌面槽位")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func slotRow(slot: DesktopWallpaperSlot, index: Int, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedSlotID = slot.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedSlotID == slot.id ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selectedSlotID == slot.id ? Color.accentColor : Color.white.opacity(0.28))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(slot.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text(slotSummary(slot))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Button {
                            moveSlot(slot.id, direction: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)

                        Button {
                            moveSlot(slot.id, direction: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == slots.count - 1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)
            }
        }
    }

    private func selectedSlotActions(slot: DesktopWallpaperSlot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("槽位名称", text: $newSlotName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

                Button("重命名") {
                    renameSlot(slot.id)
                }
                .buttonStyle(.bordered)

                Button("所有显示器选择图片") {
                    chooseImage(slotID: slot.id, screen: nil)
                }
                .buttonStyle(.bordered)
                .disabled(NSScreen.screens.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    deleteSlot(slot.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(slots.count <= 1)
            }

            Text("如果系统关闭了“显示器具有单独的 Spaces”，请用“所有显示器选择图片”广播到当前槽位；WaifuX 仍按每块显示器独立保存。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.38))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                screenActionRow(slot: slot, screen: screen, index: index)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func screenActionRow(slot: DesktopWallpaperSlot, screen: NSScreen, index: Int) -> some View {
        let entry = store.entry(slotID: slot.id, for: screen)
        let hasPending = entry.pendingAction != nil
        let isCurrent = SpaceWallpaperCoordinator.shared.identifyCurrentSpace(for: screen).slotID == slot.id

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("显示器 \(index + 1) · \(screen.localizedName)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(entryStatus(entry, isCurrent: isCurrent))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor(for: entry, isCurrent: isCurrent))
            }

            Spacer()

            Button("选择图片") {
                chooseImage(slotID: slot.id, screen: screen)
            }
            .buttonStyle(.bordered)

            Button(primaryActionTitle(for: entry, hasPending: hasPending, isCurrent: isCurrent)) {
                performPrimarySlotAction(slotID: slot.id, screen: screen, entry: entry, hasPending: hasPending, isCurrent: isCurrent)
            }
            .buttonStyle(.borderedProminent)

            if entry.currentTokenPath != nil && (hasPending || isCurrent) {
                Button("应用已保存壁纸") {
                    applySaved(slotID: slot.id, screen: screen)
                }
                .buttonStyle(.bordered)
            }

            if hasPending {
                Button("清除待应用") {
                    clearPending(slotID: slot.id, screen: screen)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func messageRow(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slotSummary(_ slot: DesktopWallpaperSlot) -> String {
        let entries = slot.screenEntries.values
        let bound = entries.filter { $0.bindingState == .bound }.count
        let pending = entries.filter { $0.pendingAction != nil }.count
        if bound == 0 && pending == 0 { return "未绑定" }
        var parts: [String] = []
        if bound > 0 { parts.append("\(bound) 个显示器已绑定") }
        if pending > 0 { parts.append("\(pending) 个待应用") }
        return parts.joined(separator: "，")
    }

    private func entryStatus(_ entry: DesktopSlotScreenEntry, isCurrent: Bool) -> String {
        var parts: [String] = []
        switch entry.bindingState {
        case .unbound:
            parts.append("未绑定")
        case .bound:
            parts.append(isCurrent ? "当前桌面" : "已绑定")
        case .lostBinding:
            parts.append("绑定丢失")
        case .displayMissing:
            parts.append("显示器缺失")
        }
        if entry.pendingAction != nil {
            parts.append("待应用")
        }
        return parts.joined(separator: " · ")
    }

    private func primaryActionTitle(for entry: DesktopSlotScreenEntry, hasPending: Bool, isCurrent: Bool) -> String {
        if hasPending {
            return "绑定并应用"
        }
        if entry.currentTokenPath != nil && !isCurrent {
            return entry.bindingState == .lostBinding ? "重新接管当前桌面" : "应用已保存壁纸"
        }
        if entry.bindingState == .lostBinding && entry.currentTokenPath != nil {
            return "重新接管当前桌面"
        }
        return "绑定当前桌面"
    }

    private func statusColor(for entry: DesktopSlotScreenEntry, isCurrent: Bool) -> Color {
        if entry.pendingAction != nil { return .orange }
        if isCurrent { return .green }
        switch entry.bindingState {
        case .lostBinding, .displayMissing:
            return .red
        case .bound:
            return Color.white.opacity(0.45)
        case .unbound:
            return Color.white.opacity(0.36)
        }
    }

    private func createSlot() {
        perform("已新建桌面槽位") {
            let slot = try store.createSlot()
            selectedSlotID = slot.id
            newSlotName = ""
        }
    }

    private func renameSlot(_ slotID: String) {
        let name = newSlotName.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("已重命名") {
            try store.renameSlot(slotID, name: name)
            newSlotName = ""
        }
    }

    private func deleteSlot(_ slotID: String) {
        perform("已删除槽位") {
            try store.deleteSlot(slotID)
            selectedSlotID = slots.first?.id
        }
    }

    private func moveSlot(_ slotID: String, direction: Int) {
        perform("已调整顺序") {
            try store.moveSlot(slotID, direction: direction)
        }
    }

    private func bind(slotID: String, screen: NSScreen, applyPending: Bool) {
        Task { @MainActor in
            do {
                try await SpaceWallpaperCoordinator.shared.bindCurrentDesktop(
                    slotID: slotID,
                    screen: screen,
                    applyPendingIfAvailable: applyPending
                )
                statusMessage = applyPending ? "已绑定当前桌面并应用待设置" : "已绑定当前桌面"
                errorMessage = nil
            } catch {
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performPrimarySlotAction(slotID: String, screen: NSScreen, entry: DesktopSlotScreenEntry, hasPending: Bool, isCurrent: Bool) {
        if hasPending {
            bind(slotID: slotID, screen: screen, applyPending: true)
        } else if entry.currentTokenPath != nil && !isCurrent {
            applySaved(slotID: slotID, screen: screen)
        } else {
            bind(slotID: slotID, screen: screen, applyPending: false)
        }
    }

    private func applySaved(slotID: String, screen: NSScreen) {
        Task { @MainActor in
            do {
                try await SpaceWallpaperCoordinator.shared.applySavedWallpaper(slotID: slotID, screen: screen)
                WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: screen.wallpaperScreenIdentifier)
                statusMessage = "已应用该槽位保存的壁纸"
                errorMessage = nil
            } catch {
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearPending(slotID: String, screen: NSScreen) {
        perform("已清除待应用") {
            try store.clearPending(slotID: slotID, screenID: screen.wallpaperScreenIdentifier)
        }
    }

    private func chooseImage(slotID: String, screen: NSScreen?) {
        let panel = NSOpenPanel()
        panel.title = "选择槽位壁纸"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        panel.begin { response in
            guard response == .OK, let imageURL = panel.url else { return }
            Task { @MainActor in
                do {
                    let targetScreens = screen.map { [$0] } ?? NSScreen.screens
                    let currentMatches = targetScreens.filter {
                        SpaceWallpaperCoordinator.shared.identifyCurrentSpace(for: $0).slotID == slotID
                    }.count
                    try await SpaceWallpaperCoordinator.shared.setStaticWallpaper(
                        imageURL,
                        option: .desktop,
                        targetScreen: screen,
                        preferredSlotID: slotID,
                        pendingKind: .pendingUserSet
                    )
                    if let screen {
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: screen.wallpaperScreenIdentifier)
                    } else {
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange()
                    }
                    statusMessage = currentMatches == targetScreens.count
                        ? "已设置到当前桌面"
                        : "已保存为待应用，切到目标桌面后绑定并应用"
                    errorMessage = nil
                } catch {
                    statusMessage = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func perform(_ success: String, action: () throws -> Void) {
        do {
            try action()
            statusMessage = success
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}
