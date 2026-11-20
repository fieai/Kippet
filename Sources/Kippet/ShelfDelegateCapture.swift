import AppKit

extension ShelfDelegate {
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    func observeCaptureConditions() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        pollingObservers = names.map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureConditionChanged(name) }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        for name in [Self.screenLocked, Self.screenUnlocked] {
            distributed.addObserver(
                self, selector: #selector(screenLockChanged(_:)), name: name,
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
        store.onCapturePauseChange = { [weak self] in self?.updateCapturePolling() }
        updateCapturePolling()
    }

    func stopObservingCaptureConditions() {
        store.onCapturePauseChange = nil
        let workspace = NSWorkspace.shared.notificationCenter
        pollingObservers.forEach { workspace.removeObserver($0) }
        pollingObservers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        for name in [Self.screenLocked, Self.screenUnlocked] {
            distributed.removeObserver(self, name: name, object: nil)
        }
        stopCapturePolling()
    }

    @objc private func screenLockChanged(_ notification: Notification) {
        captureConditionChanged(notification.name)
    }

    private func captureConditionChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: pollingState.screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: pollingState.screensAsleep = false
        case NSWorkspace.willSleepNotification: pollingState.systemAsleep = true
        case NSWorkspace.didWakeNotification: pollingState.systemAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: pollingState.sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: pollingState.sessionInactive = false
        case Self.screenLocked: pollingState.screenLocked = true
        case Self.screenUnlocked: pollingState.screenLocked = false
        default: return
        }
        updateCapturePolling()
    }

    private func updateCapturePolling() {
        guard pollingState.shouldPoll(isPaused: store.isPaused) else {
            stopCapturePolling()
            return
        }
        guard captureTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCapture() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
        scheduleCapture()
    }

    private func stopCapturePolling() {
        captureTimer?.invalidate()
        captureTimer = nil
        cancelScheduledCapture()
    }

    @objc func frontmostDidChange(_ notification: Notification) {
        activationSerial &+= 1
        if let target = pasteTarget,
           let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           active != target.application {
            keptOriginalFocus = false
            if active != .current { shelfLostFocus() }
        }
    }

    private func scheduleCapture() {
        let sameForeground = lastPolledActivation == activationSerial
        lastPolledActivation = activationSerial
        guard let change = ShelfCapturePolicy.changeToSchedule(pending: store.pendingChange, scheduled: scheduledChange)
        else { return }
        cancelScheduledCapture()
        let source = NSWorkspace.shared.frontmostApplication
        guard allowsCapture(from: source, stable: sameForeground) else {
            recordClipboard(from: source, expectedChange: change, allowed: false)
            return
        }
        if pasteStack.isCollecting {
            recordClipboard(from: source, expectedChange: change, allowed: true)
            return
        }
        scheduledChange = change
        let foregroundAtDiscovery = activationSerial
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelScheduledCapture()
                let stable = foregroundAtDiscovery == self.activationSerial
                self.recordClipboard(from: source, expectedChange: change, allowed: self.allowsCapture(from: source, stable: stable))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureSyncTimer = timer
    }

    func allowsCapture(from source: NSRunningApplication?, stable: Bool) -> Bool {
        ShelfCapturePolicy.allowsSource(
            bundleIdentifier: source?.bundleIdentifier, stable: stable, excluding: preferences.excludedApps
        )
    }

    func recordClipboard(from source: NSRunningApplication?, expectedChange: Int? = nil, allowed: Bool) {
        guard pollingState.shouldPoll(isPaused: store.isPaused) else { return }
        if store.poll(
            sourceName: source?.localizedName, sourceBundleIdentifier: source?.bundleIdentifier,
            expectedChange: expectedChange, captureAllowed: allowed
        ) {
            if preferences.copySound { NSSound(named: "Tink")?.play() }
            if pasteStack.isCollecting, let clip = store.clips.first,
               !pasteStack.append([clip]) {
                pasteStack.isCollecting = false
                status.pasteMessage = L("粘贴栈已满，连续收集已停止。")
            }
        }
    }

    func cancelScheduledCapture() {
        captureSyncTimer?.invalidate()
        captureSyncTimer = nil
        scheduledChange = nil
    }

    @objc func toggleCapture() {
        store.toggleCapture()
    }
}
