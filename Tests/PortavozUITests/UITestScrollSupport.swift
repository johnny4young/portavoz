import XCTest

extension XCUIElement {
    /// Reveals one control inside a bounded vertical viewport without fixed
    /// host-sized wheel gestures. Intermediate positions observe only a real
    /// frame change; the more expensive hittable/stable proof runs once the
    /// target is geometrically contained.
    @MainActor
    func revealVertically(
        in viewportElement: XCUIElement,
        maxScrolls: Int = 8,
        maximumStep: CGFloat = 48
    ) -> Bool {
        guard exists, viewportElement.exists, maximumStep > 0 else {
            return false
        }
        var viewportFrame = viewportElement.frame.insetBy(dx: 0, dy: 4)
        guard !viewportFrame.isEmpty else { return false }

        if viewportFrame.contains(frame),
           waitForStableContainedFrame(
               in: viewportElement,
               timeout: 1)
        {
            return true
        }

        var observedPointsPerWheelUnit: CGFloat?
        for _ in 0..<maxScrolls {
            guard exists, viewportElement.exists else { return false }
            let controlFrame = frame
            let rawViewportFrame = viewportElement.frame
            viewportFrame = rawViewportFrame.insetBy(dx: 0, dy: 4)
            guard !controlFrame.isEmpty else { return false }
            guard !viewportFrame.isEmpty else { return false }

            let desiredMovement: CGFloat
            if controlFrame.maxY > viewportFrame.maxY {
                let distance = controlFrame.maxY - viewportFrame.maxY + 8
                desiredMovement = -max(distance, 12)
            } else if controlFrame.minY < viewportFrame.minY {
                let distance = viewportFrame.minY - controlFrame.minY + 8
                desiredMovement = max(distance, 12)
            } else {
                // Geometric containment can precede AppKit hit-test ownership
                // while a transformed transcript row is settling. Move the
                // target toward the viewport center instead of returning a
                // false terminal result; native XCUI click would otherwise do
                // this same automatic reveal after the assertion has failed.
                let inwardDelta = viewportFrame.midY - controlFrame.midY
                if abs(inwardDelta) >= 1 {
                    desiredMovement = inwardDelta
                } else {
                    desiredMovement = controlFrame.midY >= viewportFrame.midY ? -12 : 12
                }
            }

            // Accessibility geometry and synthesized wheel units need not have
            // the same scale. Convert before limiting the event, otherwise a
            // short viewport can oscillate across the target on every attempt.
            let wheelMovement = desiredMovement / (observedPointsPerWheelUnit ?? 1)
            let deltaY = min(max(wheelMovement, -maximumStep), maximumStep)
            viewportElement.scroll(byDeltaX: 0, deltaY: deltaY)
            let geometryChanged = waitForUITestCondition(
                timeout: 0.5,
                pollInterval: 0.02
            ) {
                let updatedFrame = self.frame
                let updatedViewportFrame = viewportElement.frame
                return (!updatedFrame.isEmpty && updatedFrame != controlFrame)
                    || (!updatedViewportFrame.isEmpty
                        && updatedViewportFrame != rawViewportFrame)
            }

            let updatedFrame = frame
            let updatedViewportFrame = viewportElement.frame
            let displacement = updatedFrame.minY - controlFrame.minY
            if updatedViewportFrame == rawViewportFrame,
               !updatedFrame.isEmpty,
               updatedFrame.size == controlFrame.size,
               updatedFrame.minX == controlFrame.minX,
               deltaY != 0 {
                let response = displacement / deltaY
                if response.isFinite, response > 0 {
                    // A clipped or coalesced event can underestimate movement.
                    // Retain the largest response actually observed in this
                    // invocation, never a global host-specific calibration.
                    observedPointsPerWheelUnit = max(observedPointsPerWheelUnit ?? response, response)
                }
            }
            viewportFrame = updatedViewportFrame.insetBy(dx: 0, dy: 4)
            if viewportFrame.contains(updatedFrame),
               waitForStableContainedFrame(
                   in: viewportElement,
                   timeout: 1)
            {
                return true
            }
            // One synthesized wheel event can be coalesced by AppKit while a
            // scroll view is settling. Treat only the total bounded attempt
            // budget as terminal evidence that the target cannot be revealed.
            if !geometryChanged { continue }
        }
        return false
    }

    /// Materializes an accessibility element that precedes a visible semantic
    /// anchor in a SwiftUI scroll view, then applies the ordinary containment
    /// proof. SwiftUI may omit a fully clipped row from AX even when its model
    /// state has already been admitted, so existence cannot be the first gate.
    @MainActor
    func revealVertically(
        in viewportElement: XCUIElement,
        above anchorElement: XCUIElement,
        maxScrolls: Int = 6,
        maximumStep: CGFloat = 48
    ) -> Bool {
        guard viewportElement.exists,
              anchorElement.exists,
              maximumStep > 0
        else {
            return false
        }
        if exists {
            return revealVertically(
                in: viewportElement,
                maxScrolls: maxScrolls,
                maximumStep: maximumStep)
        }

        for attempt in 0..<maxScrolls {
            let anchorFrame = anchorElement.exists
                ? anchorElement.frame
                : .null
            viewportElement.scroll(byDeltaX: 0, deltaY: maximumStep)
            let materializedOrMoved = waitForUITestCondition(
                timeout: 0.5,
                pollInterval: 0.02
            ) {
                if self.exists { return true }
                guard anchorElement.exists else { return false }
                let updatedAnchorFrame = anchorElement.frame
                return !anchorFrame.isEmpty
                    && !updatedAnchorFrame.isEmpty
                    && updatedAnchorFrame != anchorFrame
            }
            if exists {
                return revealVertically(
                    in: viewportElement,
                    maxScrolls: max(0, maxScrolls - attempt - 1),
                    maximumStep: maximumStep)
            }
            // An ignored wheel event is not terminal; the total attempt count
            // remains the bounded failure authority.
            if !materializedOrMoved { continue }
        }
        return false
    }

    @MainActor
    private func waitForStableContainedFrame(
        in viewportElement: XCUIElement,
        timeout: TimeInterval,
        stableFor stableInterval: TimeInterval = 0.1
    ) -> Bool {
        var candidateFrame: CGRect?
        var stableSince: Date?
        let stableProbeInterval = stableInterval > 0 ? stableInterval : 0.05
        return waitForUITestCondition(
            timeout: timeout,
            pollInterval: stableProbeInterval
        ) {
            let controlFrame = self.frame
            let viewportFrame = viewportElement.frame.insetBy(dx: 0, dy: 4)
            guard !controlFrame.isEmpty,
                  !viewportFrame.isEmpty,
                  viewportFrame.contains(controlFrame),
                  self.isHittable
            else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            if candidateFrame != controlFrame {
                candidateFrame = controlFrame
                stableSince = Date()
                return stableInterval <= 0
            }
            guard let stableSince else { return false }
            return Date().timeIntervalSince(stableSince) >= stableInterval
        }
    }
}
