import Foundation

/// The single source of truth for the notch panel's presentation.
///
/// Notch Triage is a posture monitor now: the only transient overlay is the
/// posture alert HUD, so this type owns presentation, temporary geometry holds
/// and the revisions used to reject stale asynchronous completions.
struct PanelState: Equatable {
    enum Mode: Equatable {
        case compact
        case peek
        case workspace
        case closingWorkspace
    }

    struct EffectRevisions: Equatable {
        var hover: UInt64 = 0
        var close: UInt64 = 0
        var hud: UInt64 = 0
    }

    var mode: Mode = .compact
    var systemHUD: SystemHUDSnapshot?
    var isPointerInside = false
    var isCanvasHeldOpen = false
    var effectRevisions = EffectRevisions()

    var isExpanded: Bool {
        mode == .workspace || mode == .closingWorkspace
    }

    var isPanelClosing: Bool {
        mode == .closingWorkspace
    }

    var usesExpandedNotchShape: Bool {
        mode == .workspace || mode == .closingWorkspace
    }

    var isHoveringNotch: Bool {
        mode == .peek
    }

    var isNotchCanvasExpanded: Bool {
        geometryPhase != .compact
    }

    var windowGeometryPhase: PanelGeometryPhase {
        geometryPhase
    }

    var geometryPhase: PanelGeometryPhase {
        switch mode {
        case .workspace, .closingWorkspace:
            return .workspace
        case .peek:
            return .peek
        case .compact:
            return isCanvasHeldOpen || systemHUD != nil ? .peek : .compact
        }
    }

    mutating func reduce(_ event: PanelEvent) -> [PanelEffect] {
        switch event {
        case .pointerEntered:
            isPointerInside = true
            guard mode != .workspace, mode != .closingWorkspace else {
                return []
            }
            effectRevisions.hover &+= 1
            mode = .peek
            isCanvasHeldOpen = false
            return [.cancelHoverCollapse]

        case .pointerExited:
            isPointerInside = false
            guard mode == .peek else { return [] }
            effectRevisions.hover &+= 1
            let revision = effectRevisions.hover
            return [
                .cancelHoverCollapse,
                .scheduleHoverCollapse(revision: revision, delayMilliseconds: 130),
            ]

        case .hoverCollapseDelayElapsed(let revision):
            guard revision == effectRevisions.hover,
                  mode == .peek,
                  !isPointerInside else { return [] }
            mode = .compact
            isCanvasHeldOpen = true
            return []

        case .hoverCollapseAnimationCompleted(let revision):
            guard revision == effectRevisions.hover,
                  mode == .compact,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .workspaceOpened:
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            mode = .workspace
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
            ]

        case .workspaceCloseRequested:
            guard mode == .workspace else { return [] }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            let revision = effectRevisions.close
            mode = .closingWorkspace
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .scheduleWorkspaceClose(
                    revision: revision,
                    surfaceDelayMilliseconds: 340,
                    canvasDelayMilliseconds: 320
                ),
            ]

        case .workspaceSurfaceCloseDelayElapsed(let revision):
            guard revision == effectRevisions.close,
                  mode == .closingWorkspace else { return [] }
            mode = .compact
            isPointerInside = false
            isCanvasHeldOpen = true
            return []

        case .workspaceCanvasCloseDelayElapsed(let revision):
            guard revision == effectRevisions.close,
                  mode == .compact,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .hudReceived(let snapshot):
            guard mode != .closingWorkspace else { return [] }
            effectRevisions.hud &+= 1
            let revision = effectRevisions.hud
            systemHUD = snapshot
            if mode == .compact {
                isCanvasHeldOpen = false
            }
            return [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(
                    revision: revision,
                    delayMilliseconds: 3_200
                ),
            ]

        case .hudDismissDelayElapsed(let revision):
            guard revision == effectRevisions.hud,
                  systemHUD != nil else { return [] }
            systemHUD = nil
            if mode == .compact {
                isCanvasHeldOpen = true
            }
            return []

        case .hudDismissAnimationCompleted(let revision):
            guard revision == effectRevisions.hud,
                  mode == .compact,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .activitySuspended:
            effectRevisions.hud &+= 1
            systemHUD = nil
            if mode == .compact {
                isCanvasHeldOpen = false
            }
            return [.cancelHUDDismiss]

        case .activityResumed:
            return []

        case .reset:
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.hud &+= 1
            mode = .compact
            systemHUD = nil
            isPointerInside = false
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelHUDDismiss,
            ]
        }
    }
}

enum PanelEvent: Equatable {
    case pointerEntered
    case pointerExited
    case hoverCollapseDelayElapsed(revision: UInt64)
    case hoverCollapseAnimationCompleted(revision: UInt64)
    case workspaceOpened
    case workspaceCloseRequested
    case workspaceSurfaceCloseDelayElapsed(revision: UInt64)
    case workspaceCanvasCloseDelayElapsed(revision: UInt64)
    case hudReceived(SystemHUDSnapshot)
    case hudDismissDelayElapsed(revision: UInt64)
    case hudDismissAnimationCompleted(revision: UInt64)
    case activitySuspended
    case activityResumed
    case reset
}

enum PanelEffect: Equatable {
    case cancelHoverCollapse
    case scheduleHoverCollapse(revision: UInt64, delayMilliseconds: Int)
    case cancelWorkspaceClose
    case scheduleWorkspaceClose(
        revision: UInt64,
        surfaceDelayMilliseconds: Int,
        canvasDelayMilliseconds: Int
    )
    case cancelHUDDismiss
    case scheduleHUDDismiss(revision: UInt64, delayMilliseconds: Int)
}
