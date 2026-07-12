import AppKit
import CoreGraphics
import ApplicationServices
import ServiceManagement
import UserNotifications
import Foundation

// MARK: - 常量与日志

let APP_NAME = "访达小宝"

private let logFileURL: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return dir.appendingPathComponent("\(APP_NAME)/debug.log")
}()

/// 日志写盘放到独立串行队列，避免阻塞事件回调所在的主线程（CGEvent tap 回调里也用 writeLog）。
private let logQueue = DispatchQueue(label: "com.workbuddy.finderxiaobao.log")

/// 启动即打开一次文件句柄并缓存，避免每次写日志都 createDirectory + 重新开句柄。
private let logFileHandle: FileHandle? = {
    let dir = logFileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logFileURL.path) {
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }
    let fh = try? FileHandle(forWritingTo: logFileURL)
    fh?.seekToEndOfFile()
    return fh
}()

func writeLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    fputs(line, stderr)
    logQueue.async { logFileHandle?.write(Data(line.utf8)) }
}

// MARK: - 偏好键

private let kOnlyIconView = "onlyIconView"
private let kAccessibilityPrompted = "accessibilityPrompted"

// MARK: - 主应用代理

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 双击检测状态
    private var lastClickTime: TimeInterval = 0
    private var lastClickLoc: CGPoint = .zero

    private var doubleClickThreshold: TimeInterval { NSEvent.doubleClickInterval }
    private var doubleClickMoveTolerance: CGFloat = 6.0

    private var isEnabled = true

    // 偏好（持久化到 UserDefaults）
    private var onlyIconView: Bool {
        get { UserDefaults.standard.bool(forKey: kOnlyIconView) }
        set { UserDefaults.standard.set(newValue, forKey: kOnlyIconView) }
    }

    // 菜单项引用
    private var enabledMenuItem: NSMenuItem?
    private var onlyIconViewMenuItem: NSMenuItem?
    private var loginItemMenuItem: NSMenuItem?

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeLog("🚀 \(APP_NAME) 启动")
        writeLog("📐 双击阈值: \(doubleClickThreshold)s (系统默认), 位移容忍度: \(doubleClickMoveTolerance)pt")
        writeLog("🔒 辅助功能信任: \(AXIsProcessTrusted())")
        writeLog("🎯 触发方式: 双击（固定）, 仅图标视图: \(onlyIconView)")
        writeLog("📁 日志文件: \(logFileURL.path)")

        requestNotificationAuth()
        setupStatusItem()
        setupEventTap()
        ensureAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        writeLog("🛑 \(APP_NAME) 退出")
    }

    // MARK: 通知（UNUserNotificationCenter）

    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                writeLog("⚠️ 通知授权出错: \(error.localizedDescription)")
            } else {
                writeLog("🔔 通知授权: \(granted ? "已允许" : "被拒绝（功能不受影响，仅无提示）")")
            }
        }
    }

    private func showNotification(_ title: String, _ body: String, sound: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = NSImage(contentsOfFile: Bundle.main.path(forResource: "StatusIcon", ofType: "png") ?? "") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                       accessibilityDescription: APP_NAME)
                button.image?.isTemplate = true
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: APP_NAME, action: nil, keyEquivalent: ""))

        enabledMenuItem = NSMenuItem(title: "已启用", action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(enabledMenuItem!)
        menu.addItem(.separator())

        onlyIconViewMenuItem = NSMenuItem(title: "仅图标视图生效", action: #selector(toggleOnlyIconView), keyEquivalent: "")
        onlyIconViewMenuItem?.state = onlyIconView ? .on : .off
        menu.addItem(onlyIconViewMenuItem!)

        loginItemMenuItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginItemMenuItem!)
        updateLoginItemState()

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "📂 打开日志文件夹", action: #selector(openLogFile), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "打开「辅助功能」设置", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「自动化 · 访达」设置", action: #selector(openAutomationSettings), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enabledMenuItem?.title = isEnabled ? "已启用" : "已停用"
        writeLog("⏯️ 功能\(isEnabled ? "启用" : "停用")")
    }

    @objc private func toggleOnlyIconView() {
        onlyIconView.toggle()
        onlyIconViewMenuItem?.state = onlyIconView ? .on : .off
        writeLog("🎯 仅图标视图: \(onlyIconView)")
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                writeLog("🚪 已取消登录启动")
                showNotification("登录启动", "已取消开机自启")
            } else {
                try svc.register()
                writeLog("🚪 已设置登录启动")
                showNotification("登录启动", "已设置开机自启")
            }
        } catch {
            writeLog("⚠️ 登录项设置失败: \(error.localizedDescription)")
            showNotification("登录启动设置失败", "请在系统设置 → 通用 → 登录项中手动添加本应用")
        }
        updateLoginItemState()
    }

    private func updateLoginItemState() {
        let enabled = SMAppService.mainApp.status == .enabled
        loginItemMenuItem?.state = enabled ? .on : .off
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = APP_NAME
        alert.informativeText = """
        在访达（Finder）窗口空白处双击 → 返回上一级。

        日志位置：\(logFileURL.path)
        """
        alert.runModal()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    // MARK: 权限检查

    private func ensureAccessibilityPermission() {
        // 先用不带 prompt 的方法检查，避免每次启动都触发系统弹窗。
        guard !AXIsProcessTrusted() else {
            writeLog("✅ 辅助功能权限已授予")
            return
        }

        writeLog("⚠️ 辅助功能未授权")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }

            // 已提示过一次，就不再反复弹窗打扰用户。
            if UserDefaults.standard.bool(forKey: kAccessibilityPrompted) {
                writeLog("⚠️ 辅助功能未授权，已提示过，本次不再弹窗")
                return
            }

            // 首次未授权：弹出系统授权提示、打开设置页、显示说明弹窗，并记录已提示。
            UserDefaults.standard.set(true, forKey: kAccessibilityPrompted)
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts: CFDictionary = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)

            NSApp.activate(ignoringOtherApps: true)
            self.openAccessibilitySettings()
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = """
            本应用需要「辅助功能」权限才能监听鼠标操作。

            请在弹出的系统设置中勾选「\(APP_NAME)」，
            然后【完全退出本应用并重新打开】才能生效。

            ⚠️ 若之前已勾选过但仍无效，请先在设置里把 \(APP_NAME) 移除，
            再重新勾选并重启（每次重新编译会使旧授权失效）。
            """
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    // MARK: 事件监听

    private func setupEventTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard type != .tapDisabledByTimeout, let refcon else {
                    return Unmanaged.passRetained(event)
                }
                let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                let loc = event.location
                let now = ProcessInfo.processInfo.systemUptime

                switch type {
                case .leftMouseDown:
                    if now - app.lastClickTime < app.doubleClickThreshold &&
                        hypot(loc.x - app.lastClickLoc.x, loc.y - app.lastClickLoc.y) < app.doubleClickMoveTolerance {
                        app.lastClickTime = 0
                        writeLog("🖱️ 检测到双击 at (\(Int(loc.x)), \(Int(loc.y)))")
                        app.handleTrigger(at: loc)
                    } else {
                        app.lastClickTime = now
                        app.lastClickLoc = loc
                    }
                default:
                    break
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            writeLog("❌ 无法创建 Event Tap！请确认辅助功能权限已授予并重启。")
            showNotification("❌ Event Tap 创建失败", "需要辅助功能权限，请授权后重启")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        writeLog("✅ Event Tap 已创建并激活")
    }

    private func handleTrigger(at loc: CGPoint) {
        guard isEnabled else { writeLog("⏭️ 已停用"); return }
        DispatchQueue.main.async { [weak self] in self?.tryGoUpIfEmpty(at: loc) }
    }

    // MARK: 核心逻辑

    private func tryGoUpIfEmpty(at loc: CGPoint) {
        writeLog("━━━ 开始判定 ━━━")

        guard AXIsProcessTrusted() else {
            writeLog("❌ AXIsProcessTrusted == false")
            showNotification("权限不足", "辅助功能权限未生效")
            return
        }
        writeLog("✅ AXIsProcessTrusted == true")

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
            writeLog("⏭️ 最前面的应用不是访达，跳过")
            return
        }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &element)

        guard err == .success, let el = element else {
            writeLog("❌ AXUIElementCopyElementAtPosition 失败 (err: \(err.rawValue))")
            return
        }

        let role = axRole(of: el) ?? "(无)"
        let desc = axDescription(of: el).map { " (\($0))" } ?? ""
        writeLog("📍 命中元素 role=\(role)\(desc)")

        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success,
              let runningApp = NSRunningApplication(processIdentifier: pid) else {
            writeLog("⏭️ 不是有效进程 (pid=\(pid))")
            return
        }
        let bundleId = runningApp.bundleIdentifier ?? "unknown"
        writeLog("📦 进程: \(runningApp.localizedName ?? "?") (bundleId: \(bundleId), pid: \(pid))")

        if bundleId != "com.apple.finder" {
            writeLog("⏭️ 不是访达，跳过")
            return
        }
        writeLog("✅ 确认落在访达 (pid=\(pid))")

        if !isBlankSpace(element: el) {
            writeLog("❌ 判定为非空白处，跳过（访达照常处理，如打开文件）")
            return
        }
        writeLog("✅ 判定为空白处！执行返回...")
        goUpInFinder(requireIconView: onlyIconView)
    }

    /// 文件/文件夹本身的 Accessibility 角色，命中这些说明落在文件上，应让访达正常打开。
    private let fileContentRoles: Set<String> = [
        "AXImage",      // 图标视图中的文件/文件夹图标
        "AXRow",        // 列表/分栏视图中的文件行
        "AXCell",       // 行内的单元格
        "AXTextField"   // 行内的文件名文本
    ]

    @discardableResult
    private func isBlankSpace(element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        writeLog("  🔍 回溯 Accessibility 树:")
        while let cur = current, depth < 12 {
            let r = axRole(of: cur) ?? "(无)"
            let d = axDescription(of: cur).map { " [\($0)]" } ?? ""
            let isWindow = r == "AXWindow"
            let marker = isWindow ? " ✅(窗口)" : ""
            writeLog("    L\(depth): \(r)\(d)\(marker)")
            if fileContentRoles.contains(r) {
                writeLog("  ❌ 命中文件/文件夹元素 (\(r)) → 非空白，跳过")
                return false
            }
            if isWindow { break }
            guard let parent = axParent(of: cur) else {
                writeLog("    (无父级，终止)")
                break
            }
            current = parent
            depth += 1
        }
        writeLog("  ✅ 未命中任何文件元素且回溯到窗口 → 判定为空白")
        return true
    }

    /// 返回上一级。requireIconView 为 true 时，仅在「图标视图」下才执行（其余视图直接跳过），
    /// 视图判断与导航合并在同一次 AppleScript 调用内完成，省去额外的进程间查询。
    private func goUpInFinder(requireIconView: Bool = false) {
        let viewGuard = requireIconView
            ? "\n                if (current view of w) is not icon view then return \"wrong_view\""
            : ""
        let script = """
        tell application "Finder"
            if (count of windows) > 0 then
                try
                    set w to front window\(viewGuard)
                    set curView to current view of w
                    set t to target of w
                    set c to container of t
                    if c is not missing value then
                        set cName to name of c
                        set target of w to c
                        set current view of w to curView
                        return "ok:" & cName
                    else
                        return "at_top"
                    end if
                on error errMsg number errNum
                    return "error:" & errMsg & "(" & errNum & ")"
                end try
            end if
            return "no_window"
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            writeLog("❌ AppleScript 创建失败"); return
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let e = error {
            writeLog("❌ AppleScript 失败: \(e)")
            showNotification("执行失败", "\(e[NSAppleScript.errorMessage] ?? "?")")
        } else {
            let s = result.stringValue ?? "(无)"
            writeLog("✅ AppleScript 结果: \(s)")
            if s.hasPrefix("ok:") {
                let name = String(s.dropFirst(3))
                showNotification("↑ 已返回", "进入：\(name)", sound: true)
            } else if s == "at_top" {
                showNotification("已在最顶层", "已经是根目录，无法再返回", sound: true)
            } else if s == "no_window" {
                showNotification("无窗口", "当前没有访达窗口")
            } else if s == "wrong_view" {
                writeLog("⏭️ 仅图标视图模式，当前非图标视图，跳过")
            } else if s.hasPrefix("error:") {
                showNotification("执行失败", String(s.dropFirst(6)))
            }
        }
    }

    // MARK: AX 工具方法

    private func axRole(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func axDescription(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func axParent(of el: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &v) == .success else { return nil }
        guard let parent = v else { return nil }
        return (parent as! AXUIElement)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
