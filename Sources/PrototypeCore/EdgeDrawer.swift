import Foundation
import CoreGraphics

public struct EdgeDrawerInteraction {
    public private(set) var visible = false
    private var entered: Double?, left: Double?
    public static func isBlocked(visible: Bool, attachedDialog: Bool, dragging: Bool) -> Bool {
        dragging || (visible && attachedDialog)
    }
    public init() {}
    public mutating func reveal() { visible = true; entered = nil; left = nil }
    public mutating func hide() { visible = false; entered = nil; left = nil }
    public mutating func update(atEdge: Bool, inside: Bool, blocked: Bool, now: Double) -> Bool {
        if blocked { entered = nil; left = nil; return visible }
        if !visible && inside { reveal(); return true }
        if visible {
            if inside || atEdge { left = nil }
            else {
                if left == nil { left = now }
                if now-(left ?? now) >= 0.22 { hide() }
            }
        } else if atEdge {
            if entered == nil { entered = now }
            if now-(entered ?? now) >= 0.12 { reveal() }
        } else { entered = nil }
        return visible
    }
}
public enum EdgeDrawerGeometry {
    public static func frame(in visible: CGRect) -> CGRect {
        let width = min(visible.width,max(420,min(620,visible.width/3)))
        let margin = min(12,max(0,(visible.height-240)/2))
        return CGRect(x:visible.maxX-width,y:visible.minY+margin,width:width,height:max(1,visible.height-2*margin))
    }
}
/// Analytic critically damped spring: no accumulated integration error, continuous velocity on reversal.
public struct EdgeDrawerMotion {
    public private(set) var position = 0.0
    public private(set) var velocity = 0.0
    public init(position: Double = 0, velocity: Double = 0) {
        self.position = min(1,max(0,position)); self.velocity = velocity
    }
    public mutating func step(target: Double, dt: Double, reduceMotion: Bool = false) {
        let target = min(1,max(0,target))
        if reduceMotion { position = target; velocity = 0; return }
        let time = max(0,dt), omega = 26.0
        let delta = position-target, coefficient = velocity+omega*delta, decay = exp(-omega*time)
        position = target+(delta+coefficient*time)*decay
        velocity = (velocity-omega*coefficient*time)*decay
        if position < 0 { position = 0; velocity = 0 }
        if position > 1 { position = 1; velocity = 0 }
        if abs(position-target)<0.0005 && abs(velocity)<0.005 { position = target; velocity = 0 }
    }
}

/// Obsolete completions may neither hide a new reveal nor unlock moving controls.
public struct EdgeDrawerTransitionGuard {
    private var revision = 0
    public private(set) var blocksPointer = false
    public init() {}
    public mutating func begin(animated: Bool) -> Int {
        revision += 1; blocksPointer = animated; return revision
    }
    public mutating func complete(_ candidate: Int) -> Bool {
        guard candidate == revision else { return false }
        blocksPointer = false; return true
    }
}
