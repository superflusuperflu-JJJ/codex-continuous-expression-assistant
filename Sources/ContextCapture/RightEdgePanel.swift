import AppKit
import SwiftUI
import QuartzCore
import PrototypeCore

private final class DrawerPanel: NSPanel {
    var blocksPointer = false
    override func sendEvent(_ event: NSEvent) {
        // Layer transforms don't relocate AppKit's hit regions during the slide.
        // Swallow pointer actions until the current transition settles; typing still works.
        if blocksPointer && [.leftMouseDown,.leftMouseUp,.leftMouseDragged,.rightMouseDown,.rightMouseUp,.rightMouseDragged,.otherMouseDown,.otherMouseUp,.otherMouseDragged,.scrollWheel].contains(event.type) { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hover reads don't activate the app. Only the compositor moves the cached view layers.
@MainActor final class RightEdgePanel {
    private let delivery: DesktopAccessibilityProbe
    private var suppressHoverUntilExit = false
    private let panel: DrawerPanel
    private let canvas = NSView(frame:.zero), movingView = NSView(frame:.zero)
    private var interaction = EdgeDrawerInteraction(), motion = EdgeDrawerMotion()
    private var motionTarget = 0.0, motionTime = ProcessInfo.processInfo.systemUptime
    private var transition = EdgeDrawerTransitionGuard()
    private var polling: Timer?
    private var screenObserver: NSObjectProtocol?, accessibilityObserver: NSObjectProtocol?
    private var revealGraceUntil = 0.0
    private var enabled = false
    private var hostScreen: NSScreen?
    init(model: SessionModel, settings: EdgePanelSettings) {
        delivery = model.desktopDelivery
        panel = DrawerPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title = "Codex连续表达助手"
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let content = CompactCaptureView(model:model,settings:settings,onWillFill:{ [weak self] in self?.hideForDelivery() },onFillFailure:{ [weak self] in self?.reveal(activate:true) })
        let host = NSHostingView(rootView:content.frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(.primary.opacity(0.1))))
        host.sizingOptions = []; host.autoresizingMask = [.width,.height]
        canvas.wantsLayer = true; canvas.layer?.masksToBounds = true
        movingView.wantsLayer = true; movingView.autoresizingMask = [.width,.height]
        canvas.addSubview(movingView); movingView.addSubview(host); panel.contentView = canvas
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.animate(immediate:true) }
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; polling?.invalidate(); polling = nil
        if value {
            reposition()
            let timer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in Task { @MainActor in self?.pollPointer() } }
            polling = timer; RunLoop.main.add(timer,forMode:.common)
        } else { hideImmediately() }
    }
    func reveal(activate: Bool = false) {
        guard enabled else { return }
        suppressHoverUntilExit = false
        if !panel.isVisible { reposition() }
        revealGraceUntil = ProcessInfo.processInfo.systemUptime+1.2
        interaction.reveal(); panel.orderFrontRegardless(); animate()
        if activate { NSApp.activate(ignoringOtherApps:true); panel.makeKeyAndOrderFront(nil) }
    }
    private func hideForDelivery() {
        suppressHoverUntilExit = true
        hideImmediately()
    }
    func hideImmediately() {
        interaction.hide(); animate(immediate:true)
    }
    func stop() {
        enabled = false; polling?.invalidate(); polling = nil; hideImmediately()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
    private func place(on screen: NSScreen) {
        panel.setFrame(EdgeDrawerGeometry.frame(in:screen.visibleFrame),display:false)
        // Views stay at fixed frames for text layout and hit testing; only the outer layer translates.
        movingView.frame = canvas.bounds
        movingView.subviews.first?.frame = movingView.bounds
        animate(immediate:true)
    }
    private func reposition() {
        let point = NSEvent.mouseLocation
        hostScreen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = hostScreen { place(on:screen) }
    }
    private func pollPointer() {
        guard enabled else { return }
        let point = NSEvent.mouseLocation, over = NSScreen.screens.first { $0.frame.contains(point) }
        if !interaction.visible && !panel.isVisible, let over, hostScreen !== over {
            hostScreen = over; place(on:over)
        }
        guard let screen = hostScreen else { return }
        let edge = point.x >= screen.frame.maxX-3 && point.x <= screen.frame.maxX && point.y >= screen.visibleFrame.minY && point.y <= screen.visibleFrame.maxY
        if suppressHoverUntilExit {
            // A send click must not immediately re-open the drawer beneath the
            // stationary pointer. Failure or explicit reveal clears this latch.
            if delivery.busy || edge || NSEvent.pressedMouseButtons != 0 { return }
            suppressHoverUntilExit = false
        }
        let inside = panel.isVisible && panel.frame.contains(point)
        if inside { revealGraceUntil = 0 }
        let blocked = ProcessInfo.processInfo.systemUptime < revealGraceUntil || EdgeDrawerInteraction.isBlocked(visible:interaction.visible,attachedDialog:panel.attachedSheet != nil || NSApp.modalWindow != nil,dragging:NSEvent.pressedMouseButtons != 0)
        let before = interaction.visible
        _ = interaction.update(atEdge:edge,inside:inside,blocked:blocked,now:ProcessInfo.processInfo.systemUptime)
        if before != interaction.visible {
            if interaction.visible { panel.orderFrontRegardless() }
            animate()
        }
    }
    private func animate(immediate: Bool = false) {
        guard let layer = movingView.layer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        motion.step(target:motionTarget,dt:now-motionTime)
        let width = max(1,movingView.bounds.width)
        let visibleX = layer.presentation()?.transform.m41 ?? layer.transform.m41
        let start = max(0,min(1,1-Double(visibleX/width)))
        motion = EdgeDrawerMotion(position:start,velocity:motion.velocity)
        motionTime = now; motionTarget = interaction.visible ? 1 : 0
        let target = motionTarget
        let reduced = immediate || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let generation = transition.begin(animated:!reduced)
        panel.blocksPointer = transition.blocksPointer
        // Build the spring curve once. No per-frame SwiftUI updates, timer, or text re-layout.
        let duration = 0.4
        var sample = motion
        var values: [CGFloat] = [CGFloat(1-start)*width]
        for _ in 1...90 {
            sample.step(target:target,dt:duration/90)
            values.append(CGFloat(1-sample.position)*width)
        }
        values[values.count-1] = CGFloat(1-target)*width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey:"drawerSlide")
        layer.transform = CATransform3DMakeTranslation(CGFloat(1-target)*width,0,0)
        panel.ignoresMouseEvents = target == 0 && reduced
        if !reduced {
            let animation = CAKeyframeAnimation(keyPath:"transform.translation.x")
            animation.values = values; animation.duration = duration; animation.calculationMode = .linear
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor in self?.complete(generation:generation,target:target) }
            }
            layer.add(animation,forKey:"drawerSlide")
        }
        CATransaction.commit()
        if reduced { complete(generation:generation,target:target) }
    }
    private func complete(generation: Int, target: Double) {
        // A cancelled hide must never order out a newly revealed drawer.
        guard transition.complete(generation) else { return }
        panel.blocksPointer = transition.blocksPointer
        panel.ignoresMouseEvents = target == 0
        motion.step(target:target,dt:0,reduceMotion:true); motionTime = ProcessInfo.processInfo.systemUptime
        if target == 0 { panel.orderOut(nil) }
    }
}
