import CoreGraphics
import XCTest

@testable import NotchTriage

final class PanelStateTests: XCTestCase {
    func testInitialStateProjectsCompactPresentation() {
        let state = PanelState()

        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .compact)
        XCTAssertEqual(state.windowGeometryPhase, .compact)
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPanelClosing)
        XCTAssertFalse(state.usesExpandedNotchShape)
        XCTAssertFalse(state.isHoveringNotch)
        XCTAssertFalse(state.isNotchCanvasExpanded)
    }

    func testHoverCollapseRejectsStaleCompletionAfterPointerReenters() {
        var state = PanelState()
        XCTAssertEqual(state.reduce(.pointerEntered), [.cancelHoverCollapse])
        XCTAssertEqual(state.mode, .peek)

        XCTAssertEqual(
            state.reduce(.pointerExited),
            [
                .cancelHoverCollapse,
                .scheduleHoverCollapse(revision: 2, delayMilliseconds: 130),
            ]
        )
        XCTAssertEqual(
            state.reduce(.hoverCollapseDelayElapsed(revision: 2)),
            []
        )
        XCTAssertEqual(state.mode, .compact)
        XCTAssertTrue(state.isCanvasHeldOpen)

        _ = state.reduce(.pointerEntered)
        _ = state.reduce(.hoverCollapseAnimationCompleted(revision: 2))

        XCTAssertEqual(state.mode, .peek)
        XCTAssertFalse(state.isCanvasHeldOpen)
    }

    func testWorkspaceClosePreservesTargetVersionTwoStageCanvasRelease() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        XCTAssertTrue(state.usesExpandedNotchShape)

        XCTAssertEqual(
            state.reduce(.workspaceCloseRequested),
            [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
                .scheduleWorkspaceClose(
                    revision: 2,
                    surfaceDelayMilliseconds: 340,
                    canvasDelayMilliseconds: 320
                ),
            ]
        )
        XCTAssertEqual(state.mode, .closingWorkspace)
        XCTAssertEqual(state.geometryPhase, .workspace)
        XCTAssertEqual(state.windowGeometryPhase, .workspace)
        XCTAssertTrue(state.usesExpandedNotchShape)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))
        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .peek)
        XCTAssertEqual(state.windowGeometryPhase, .peek)
        XCTAssertTrue(state.isCanvasHeldOpen)

        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))
        XCTAssertFalse(state.isCanvasHeldOpen)
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testReopeningWorkspaceInvalidatesOldCloseCallbacks() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)
        _ = state.reduce(.workspaceOpened)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))
        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))

        XCTAssertEqual(state.mode, .workspace)
        XCTAssertEqual(state.geometryPhase, .workspace)
    }

    func testPointerEventsDuringClosingDoNotChangeTargetVersionClose() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)
        _ = state.reduce(.pointerEntered)
        XCTAssertEqual(state.geometryPhase, .workspace)
        XCTAssertEqual(state.windowGeometryPhase, .workspace)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))

        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .peek)
        XCTAssertFalse(state.isPointerInside)

        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testPostureHUDUsesFixedTimeoutAndRejectsStaleDismissal() {
        var state = PanelState()
        let bad = SystemHUDSnapshot.posture(PostureAlert(kind: .badPosture))
        let good = SystemHUDSnapshot.posture(PostureAlert(kind: .good))

        XCTAssertEqual(
            state.reduce(.hudReceived(bad)),
            [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(revision: 1, delayMilliseconds: 3_200),
            ]
        )
        XCTAssertEqual(state.geometryPhase, .peek)

        XCTAssertEqual(
            state.reduce(.hudReceived(good)),
            [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(revision: 2, delayMilliseconds: 3_200),
            ]
        )
        _ = state.reduce(.hudDismissDelayElapsed(revision: 1))
        XCTAssertEqual(state.systemHUD, good)

        _ = state.reduce(.hudDismissDelayElapsed(revision: 2))
        XCTAssertNil(state.systemHUD)
        XCTAssertTrue(state.isCanvasHeldOpen)
        _ = state.reduce(.hudDismissAnimationCompleted(revision: 2))
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testClosingWorkspaceBlocksHUD() {
        var state = PanelState()
        let alert = SystemHUDSnapshot.posture(PostureAlert(kind: .badPosture))
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)

        XCTAssertEqual(state.reduce(.hudReceived(alert)), [])
        XCTAssertNil(state.systemHUD)
    }

    func testActivitySuspensionClearsHUDAndCanvasHold() {
        var state = PanelState()
        _ = state.reduce(.hudReceived(.posture(PostureAlert(kind: .badPosture))))
        let revision = state.effectRevisions.hud
        _ = state.reduce(.hudDismissDelayElapsed(revision: revision))
        XCTAssertTrue(state.isCanvasHeldOpen)

        XCTAssertEqual(state.reduce(.activitySuspended), [.cancelHUDDismiss])
        XCTAssertNil(state.systemHUD)
        XCTAssertFalse(state.isCanvasHeldOpen)
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testXCTestHostDoesNotStartLongLivedAppServices() {
        XCTAssertFalse(
            AppDelegate.shouldStartAppServices(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
        XCTAssertTrue(AppDelegate.shouldStartAppServices(environment: [:]))
    }

    func testPanelHeightsPreserveExistingGeometry() {
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .compact),
            32
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .peek),
            74
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 90, phase: .peek),
            90
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .workspace),
            550
        )
    }

    func testWindowAndVisibleSurfaceFramesShareOneProjection() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let peek = NotchLayout.geometry(
            screenFrame: screen,
            menuBarHeight: 32,
            phase: .peek,
            compactSurfaceWidth: 272,
            compactSurfaceHorizontalOffset: -18.5
        )
        XCTAssertEqual(peek.windowFrame, CGRect(x: 476, y: 908, width: 560, height: 74))
        XCTAssertEqual(
            peek.hoverTrackingFrame,
            CGRect(x: 601.5, y: 908, width: 272, height: 74)
        )
        XCTAssertEqual(peek.dropHitFrame, peek.hoverTrackingFrame)

        let workspace = NotchLayout.geometry(
            screenFrame: screen,
            menuBarHeight: 32,
            phase: .workspace
        )
        XCTAssertEqual(
            workspace.windowFrame,
            CGRect(x: 476, y: 432, width: 560, height: 550)
        )
        XCTAssertEqual(
            workspace.visibleSurfaceFrame,
            CGRect(x: 496, y: 432, width: 520, height: 550)
        )
        XCTAssertEqual(
            workspace.hoverTrackingFrame,
            CGRect(x: 476, y: 908, width: 560, height: 74)
        )
        XCTAssertEqual(workspace.dropHitFrame, workspace.hoverTrackingFrame)
        XCTAssertTrue(workspace.visibleSurfaceFrame.contains(CGPoint(x: 496, y: 500)))
        XCTAssertFalse(workspace.visibleSurfaceFrame.contains(CGPoint(x: 495, y: 500)))
    }

    func testMenuBarHeightUsesExistingMinimum() {
        let screen = CGRect(x: 100, y: 50, width: 1_200, height: 900)
        XCTAssertEqual(
            NotchLayout.menuBarHeight(
                screenFrame: screen,
                visibleFrame: CGRect(x: 100, y: 50, width: 1_200, height: 876)
            ),
            32
        )
        XCTAssertEqual(
            NotchLayout.menuBarHeight(
                screenFrame: screen,
                visibleFrame: CGRect(x: 100, y: 50, width: 1_200, height: 852)
            ),
            48
        )
    }

    func testCompactSurfaceAndNotchFallbacksAreCentralized() {
        XCTAssertEqual(
            NotchLayout.compactSurfaceWidth(
                leftWingWidth: 37,
                notchWidth: 186,
                rightWingWidth: 37
            ),
            272
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 272),
            272
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 510),
            510
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 800),
            560
        )
        XCTAssertEqual(
            NotchLayout.compactSurfaceHorizontalOffset(
                leftWingWidth: 37,
                rightWingWidth: 0
            ),
            -18.5
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: false,
                measuredWidth: nil
            ),
            168
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: true,
                measuredWidth: .nan
            ),
            186
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: true,
                measuredWidth: 220
            ),
            220
        )
    }
}
