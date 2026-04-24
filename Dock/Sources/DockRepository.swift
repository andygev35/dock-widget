//
//  DockRepository.swift
//  Dock
//
//  Created by Pierluigi Galdi on 21/11/20.
//  Copyright © 2020 Pierluigi Galdi. All rights reserved.
//

protocol DockDelegate: AnyObject {
    func didUpdateDockItem(_ item: DockItem, at index: Int, terminated: Bool, isDefaults: Bool)
    func didUpdateActiveItem(_ item: DockItem, at index: Int, activated: Bool)
    func didUpdatePersistentItem(_ item: DockItem, at index: Int, added: Bool)
    func didUpdateBadge(for apps: [DockItem])
}

class DockRepository {
    
    /// Delegate
    private weak var dockDelegate: DockDelegate?
    
    /// Core
    private var fileMonitor: FileMonitor!
    private var notificationBadgeRefreshTimer: Timer!
    /// Fallback reload timer for Sonoma — dock plist changes aren't always caught by FileMonitor
    private var dockReloadTimer: Timer?
    private var shouldShowNotificationBadge: Bool {
        let refreshInterval: NotificationBadgeRefreshRateKeys = Preferences[.notificationBadgeRefreshInterval]
        return refreshInterval != .never
    }
    private var showOnlyRunningApps: Bool { return Preferences[.showOnlyRunningApps] }
    private var openFinderInsidePock: Bool { return Preferences[.openFinderInsidePock] }
    private var dockFolderRepository: DockFolderRepository?
    private var keyValueObservers: [NSKeyValueObservation] = []
    
    /// Data
    private var defaultItems: [DockItem]     = []
    private var runningItems: [DockItem]     = []
    private var persistentItems: [DockItem] = []
    private var dockItems: [DockItem] {
        if Preferences[.showOnlyRunningApps] {
            return self.runningItems
        }
        return runningItems + defaultItems.filter({ runningItems.contains($0) == false })
    }
    
    /// Default initialiser
    init(delegate: DockDelegate) {
        self.dockDelegate = delegate
        self.dockFolderRepository = DockFolderRepository()
        self.registerForEventsAndNotifications()
        self.setupNotificationBadgeRefreshTimer()
        self.startDockReloadTimer()
        self.reloadDockItems(nil)
    }
    
    /// Deinit
    deinit {
        self.notificationBadgeRefreshTimer?.invalidate()
        self.dockReloadTimer?.invalidate()
        self.unregisterFromEventsAndNotifications()
        dockFolderRepository = nil
        defaultItems.removeAll()
        runningItems.removeAll()
        persistentItems.removeAll()
    }
    
    /// Update notification badge refresh timer
    @objc private func setupNotificationBadgeRefreshTimer() {
        let refreshRate: NotificationBadgeRefreshRateKeys = Preferences[.notificationBadgeRefreshInterval]
        self.notificationBadgeRefreshTimer?.invalidate()
        guard refreshRate.rawValue >= 0 else {
            return
        }
        self.notificationBadgeRefreshTimer = Timer.scheduledTimer(withTimeInterval: refreshRate.rawValue, repeats: true, block: { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateNotificationBadges()
            }
        })
    }

    /// Fallback timer to periodically reload dock items where FileMonitor
    /// may miss dock plist changes due to macOS preference caching
    private func startDockReloadTimer() {
        dockReloadTimer?.invalidate()
        dockReloadTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.loadDefaultItems()
                self?.loadPersistentItems()
            }
        }
    }

    /// Read dock preferences reliably using CFPreferences (bypasses UserDefaults cache)
    private func readDockPreferences() -> [String: Any]? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return UserDefaults.standard.persistentDomain(forName: "com.apple.dock")
    }

}

// MARK: Register/Unregister from event and notifications
extension DockRepository {
    
    private func registerForEventsAndNotifications() {
        registerForRunningAppsEvents()
        registerForWorkspaceNotifications()
        registerForInternalNotifications()
        fileMonitor = FileMonitor(paths: [Constants.trashPath, Constants.dockPlist], delegate: self)
    }
    
    private func unregisterFromEventsAndNotifications() {
        fileMonitor = nil
        keyValueObservers.forEach { $0.invalidate() }
        keyValueObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    private func registerForRunningAppsEvents() {
        self.keyValueObservers = [
            NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new], changeHandler: { [weak self] _, change in
                if let apps = change.newValue {
                    for app in apps {
                        self?.updateRunningState(for: app, wasLaunched: true)
                    }
                } else if let apps = change.oldValue {
                    for app in apps {
                        self?.updateRunningState(for: app, wasTerminated: true)
                    }
                } else {
                    self?.loadRunningItems()
                }
            })
        ]
    }
    
    private func registerForWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(updateActiveState(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(updateActiveState(_:)),
                                                          name: NSWorkspace.didDeactivateApplicationNotification,
                                                          object: nil)
    }
    
    private func registerForInternalNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(self.setupNotificationBadgeRefreshTimer),
                                                          name: .didChangeNotificationBadgeRefreshRate,
                                                          object: nil)
    }
    
}

// MARK: Load items
extension DockRepository {
    
    @objc private func reloadDockItems(_ notification: NSNotification?) {
        loadRunningItems()
        loadDefaultItems()
        loadPersistentItems()
    }
    
    @objc private func loadRunningItems() {
        for app in NSWorkspace.shared.runningApplications {
            updateRunningState(for: app)
        }
    }
    
    @objc private func loadDefaultItems() {
        guard let dict = readDockPreferences() else {
            NSLog("[DockWidget]: Can't read Dock preferences file")
            return
        }
        guard let apps = dict["persistent-apps"] as? [[String: Any]] else {
            NSLog("[DockWidget]: Can't get persistent apps")
            return
        }
        defaultItems.removeAll(where: { item in self.runningItems.contains(where: { $0.bundleIdentifier == item.bundleIdentifier }) == false })
        /// Add Finder item, if needed
        if Preferences[.hideFinder] {
            if let item = defaultItems.first(where: { $0.bundleIdentifier == Constants.kFinderIdentifier }) {
                dockDelegate?.didUpdateDockItem(item, at: item.index, terminated: true, isDefaults: false)
                defaultItems.removeAll(where: { $0.diffId == item.diffId })
            }
        } else if defaultItems.contains(where: { $0.bundleIdentifier == Constants.kFinderIdentifier }) == false {
            let item = DockItem(0, Constants.kFinderIdentifier, name: "Finder", path: nil, icon: DockRepository.getIcon(forBundleIdentifier: Constants.kFinderIdentifier))
            defaultItems.insert(item, at: 0)
            dockDelegate?.didUpdateDockItem(item, at: 0, terminated: false, isDefaults: true)
        }
        guard Preferences[.showOnlyRunningApps] == false else {
            for (index, item) in runningItems.enumerated() {
                dockDelegate?.didUpdateDockItem(item, at: index, terminated: false, isDefaults: false)
            }
            return
        }
        for (index, app) in apps.enumerated() {
            guard let dataTile = app["tile-data"] as? [String: Any] else {
                NSLog("[DockWidget]: Can't get app tile-data")
                continue
            }
            guard let label = dataTile["file-label"] as? String else {
                NSLog("[DockWidget]: Can't get app label")
                continue
            }
            /// Get file-data for path fallback (used by Wine/Whisky apps without bundle identifier)
            let fileData = dataTile["file-data"] as? [String: Any]
            let appPathString = (fileData?["_CFURLString"] as? String)?
                .replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding
            /// bundle-identifier may be absent for Wine/Whisky wrapper apps
            let bundleIdentifier = dataTile["bundle-identifier"] as? String
            /// Skip if neither bundle ID nor path available
            guard bundleIdentifier != nil || appPathString != nil else {
                NSLog("[DockWidget]: Skipping item '\(label)' — no bundle identifier or path")
                continue
            }
            /// Check if item already exists by bundle ID or path
            let alreadyExists = defaultItems.contains(where: {
                if let bid = bundleIdentifier, let existingBid = $0.bundleIdentifier {
                    return bid == existingBid
                }
                if let path = appPathString, let existingPath = $0.path?.path {
                    return path == existingPath
                }
                return false
            })
            guard alreadyExists == false else { continue }
            /// Get icon — prefer bundle ID, fall back to path
            let icon: NSImage?
            if let bid = bundleIdentifier {
                icon = DockRepository.getIcon(forBundleIdentifier: bid)
            } else {
                icon = DockRepository.getIcon(orPath: appPathString)
            }
            /// Build path URL for path-based apps (e.g. Wine/Whisky wrappers)
            let itemPath: URL? = appPathString != nil ? URL(fileURLWithPath: appPathString!) : nil
            let item = DockItem(index + (Preferences[.hideFinder] ? 0 : 1),
                                bundleIdentifier,
                                name: label,
                                path: itemPath,
                                icon: icon,
                                pid_t: 0,
                                launching: false)
            defaultItems.append(item)
            dockDelegate?.didUpdateDockItem(item, at: item.index, terminated: false, isDefaults: true)
        }
    }
    
    @objc private func loadPersistentItems() {
        guard let dict = readDockPreferences() else {
            NSLog("[DockWidget]: Can't read Dock preferences file")
            return
        }
        guard let apps = dict["persistent-others"] as? [[String: Any]] else {
            NSLog("[DockWidget]: Can't get persistent apps")
            return
        }
        var tmpPersistentItems: [DockItem] = []
        for (index, app) in apps.enumerated() {
            guard let dataTile = app["tile-data"] as? [String: Any] else { NSLog("[DockWidget]: Can't get file tile-data"); continue }
            guard let label = dataTile["file-label"] as? String else { NSLog("[DockWidget]: Can't get file label"); continue }
            guard let fileData = dataTile["file-data"] as? [String: Any] else { NSLog("[DockWidget]: Can't get file data"); continue }
            guard let path = fileData["_CFURLString"] as? String else { NSLog("[DockWidget]: Can't get file path"); continue }
            let item = DockItem(index,
                                nil,
                                name: label,
                                path: URL(string: path),
                                icon: DockRepository.getIcon(orPath: path.replacingOccurrences(of: "file://", with: "")),
                                launching: false,
                                persistentItem: true)
            if persistentItems.contains(item) == false {
                persistentItems.append(item)
            }
            tmpPersistentItems.append(item)
            dockDelegate?.didUpdatePersistentItem(item, at: index, added: true)
        }
        for removedItem in persistentItems.enumerated().filter({ tmpPersistentItems.contains($0.element) == false }) {
            if removedItem.element.name == "Trash" {
                continue
            }
            persistentItems.remove(at: removedItem.offset)
            dockDelegate?.didUpdatePersistentItem(removedItem.element, at: removedItem.offset, added: false)
        }
        if Preferences[.hideTrash] {
            if let item = persistentItems.first(where: { $0.path?.absoluteString == Constants.trashPath }) {
                dockDelegate?.didUpdatePersistentItem(item, at: item.index, added: false)
                persistentItems.removeAll(where: { $0.diffId == item.diffId })
            }
        } else if persistentItems.contains(where: { $0.path?.absoluteString == Constants.trashPath }) == false {
            let trashType = ((try? FileManager.default.contentsOfDirectory(atPath: Constants.trashPath).isEmpty) ?? true) ? "TrashIcon" : "FullTrashIcon"
            let item = DockItem(
                self.persistentItems.count,
                nil,
                name: "Trash",
                path: URL(string: "file://"+Constants.trashPath)!,
                icon: DockRepository.getIcon(orType: trashType),
                persistentItem: true)
            persistentItems.append(item)
            dockDelegate?.didUpdatePersistentItem(item, at: item.index, added: true)
        }
    }
    
}

// MARK: Updates items
extension DockRepository {
    
    private var lastValidDockItemsIndex: Int {
        let count = self.dockItems.count
        guard count > 0 else { return 0 }
        return count - 1
    }
    
    private func createItem(for app: NSRunningApplication) -> DockItem? {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Constants.kFinderIdentifier else {
            return nil
        }
        guard let localizedName = app.localizedName,
              let bundleURL     = app.bundleURL,
              let icon          = app.icon else {
            return nil
        }
        return DockItem(0, id, name: localizedName, path: bundleURL, icon: icon, pid_t: app.processIdentifier, launching: app.isFinishedLaunching == false)
    }
    
    private func updateRunningState(for app: NSRunningApplication, wasLaunched: Bool = false, wasTerminated: Bool = false) {
        guard app.activationPolicy == .regular else {
            return
        }
        DispatchQueue.main.async { [weak self, app] in
            guard let self = self else { return }
            guard let item = self.defaultItems.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
                guard let runningItem = self.runningItems.enumerated().first(where: { $0.element.bundleIdentifier == app.bundleIdentifier }) else {
                    if let item = self.createItem(for: app) {
                        self.runningItems.append(item)
                        self.dockDelegate?.didUpdateDockItem(item, at: self.lastValidDockItemsIndex, terminated: false, isDefaults: false)
                    }
                    return
                }
                if wasTerminated {
                    self.runningItems.remove(at: runningItem.offset)
                    self.dockDelegate?.didUpdateDockItem(runningItem.element, at: self.lastValidDockItemsIndex, terminated: true, isDefaults: false)
                }
                return
            }
            item.name  = app.localizedName ?? item.name
            item.icon  = app.icon ?? item.icon
            item.pid_t = wasTerminated ? 0 : app.processIdentifier
            if let runningItemIndex = self.runningItems.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                if wasTerminated {
                    self.runningItems.remove(at: runningItemIndex)
                }
            } else {
                if wasLaunched {
                    self.runningItems.append(item)
                }
            }
            self.dockDelegate?.didUpdateDockItem(item, at: self.lastValidDockItemsIndex, terminated: wasTerminated, isDefaults: true)
        }
        NSLog("[DockRepositoryEvo]: Update running state for app: [\(app.bundleIdentifier ?? "<unknown-app-\(app)>")]")
    }
    
    @objc private func updateActiveState(_ notification: NSNotification?) {
        DispatchQueue.main.async { [weak self, notification] in
            guard let self = self else { return }
            if let app = notification?.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                if let result = self.dockItems.enumerated().first(where: { $0.element.bundleIdentifier == app.bundleIdentifier }) {
                    result.element.isLaunching = false
                    self.dockDelegate?.didUpdateActiveItem(result.element, at: result.offset, activated: notification?.name == NSWorkspace.didActivateApplicationNotification)
                }
            }
        }
    }

}

// MARK: App icon's badge
extension DockRepository {
    private func updateNotificationBadges() {
        guard shouldShowNotificationBadge, let delegate = self.dockDelegate else { return }
        for item in dockItems {
            item.badge = PockDockHelper().getBadgeCountForItem(withName: item.name)
        }
        delegate.didUpdateBadge(for: self.dockItems)
    }
}

// MARK: File Monitor Delegate
extension DockRepository: FileMonitorDelegate {
    func didChange(fileMonitor: FileMonitor, paths: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.loadPersistentItems()
        }
    }
}

// MARK: Get app/file icon
extension DockRepository {
    public class func getIcon(forBundleIdentifier bundleIdentifier: String? = nil, orPath path: String? = nil, orType type: String? = nil) -> NSImage? {
        if let bundleIdentifier = bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        if let path = path?.removingPercentEncoding {
            return NSWorkspace.shared.icon(forFile: path)
        }
        var genericIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"
        if let type = type {
            if type == "directory-tile" {
                genericIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns"
            } else if type == "TrashIcon" || type == "FullTrashIcon" {
                genericIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(type).icns"
            }
        }
        return NSImage(contentsOfFile: genericIconPath) ?? NSImage(size: .zero)
    }
    
    public func launch(bundleIdentifier: String?, completion: (Bool) -> ()) {
        guard let bundleIdentifier = bundleIdentifier else {
            completion(false)
            return
        }
        var returnable: Bool = false
        if bundleIdentifier.contains("file://") {
            let path: String = bundleIdentifier
            var isDirectory: ObjCBool = true
            let url: URL = URL(string: path)!
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue && openFinderInsidePock {
                dockFolderRepository?.popToRootDockFolderController()
                dockFolderRepository?.push(url)
                returnable = true
            } else {
                returnable = NSWorkspace.shared.open(url)
            }
        } else {
            if bundleIdentifier.lowercased() == Constants.kFinderIdentifier && openFinderInsidePock {
                dockFolderRepository?.popToRootDockFolderController()
                dockFolderRepository?.push(URL(string: NSHomeDirectory())!)
                returnable = true
            } else {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                        if let error = error {
                            NSLog("[DockRepository]: Failed to launch \(bundleIdentifier): \(error.localizedDescription)")
                        }
                    }
                    returnable = true
                }
            }
        }
        completion(returnable)
    }

    public func launch(item: DockItem?, completion: (Bool) -> ()) {
        guard let _item = item else {
            completion(false)
            return
        }
        /// If no bundle identifier (e.g. Wine/Whisky wrapper), launch by path directly
        guard let identifier = _item.bundleIdentifier else {
            if let url = _item.path {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    if let error = error {
                        NSLog("[DockRepository]: Failed to launch path-based app '\(_item.name)': \(error.localizedDescription)")
                    }
                }
                completion(true)
            } else {
                completion(false)
            }
            return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard _item.bundleIdentifier?.lowercased() != Constants.kFinderIdentifier else {
            launch(bundleIdentifier: _item.bundleIdentifier ?? _item.path?.absoluteString, completion: completion)
            return
        }
        guard apps.count > 0 else {
            launch(bundleIdentifier: _item.bundleIdentifier ?? _item.path?.absoluteString, completion: completion)
            return
        }
        if apps.count > 1 {
            var result = false
            for app in apps {
                result = activate(app: app)
                if result == false { break }
            }
            completion(result)
        } else {
            completion(activate(app: apps.first))
        }
    }
    
    @discardableResult
    private func activate(app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        let _windows = PockDockHelper().getWindowsOfApp(app.processIdentifier) as NSArray?
        if let windows = _windows as? [AppExposeItem], activateExpose(with: windows, app: app) {
            return true
        } else {
            if !app.unhide() {
                if let bundleId = app.bundleIdentifier,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                } else if let bundleURL = app.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: nil)
                } else {
                    return app.activate(options: .activateIgnoringOtherApps)
                }
            }
            return true
        }
    }
    
    private func activateExpose(with windows: [AppExposeItem], app: NSRunningApplication) -> Bool {
        guard windows.count > 0 else { return false }
        let settings: AppExposeSettings = Preferences[.appExposeSettings]
        guard settings == .always || (settings == .ifNeeded && windows.count > 1) else {
            PockDockHelper().activate(windows.first, in: app)
            return false
        }
        openExpose(with: windows, for: app)
        return true
    }
    
    public func openExpose(with windows: [AppExposeItem], for app: NSRunningApplication) {
        let controller: AppExposeController = AppExposeController.load()
        controller.set(app: app)
        controller.set(elements: windows)
        controller.pushOnMainNavigationController()
    }
    
}
