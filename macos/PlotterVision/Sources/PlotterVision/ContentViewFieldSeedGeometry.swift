import CoreGraphics
import Foundation

extension ContentView {
    func seededFieldCorners(
        from model: MachineVideoAgreementModel,
        center: CGPoint,
        fieldWidthMm: Double,
        fieldHeightMm: Double
    ) -> [ManualFiducialPoint]? {
        let xVector = CGVector(
            dx: CGFloat(model.xBasisDxNorm * fieldWidthMm),
            dy: CGFloat(model.xBasisDyNorm * fieldWidthMm)
        )
        let yVector = CGVector(
            dx: CGFloat(model.yBasisDxNorm * fieldHeightMm),
            dy: CGFloat(model.yBasisDyNorm * fieldHeightMm)
        )
        guard hypot(xVector.dx, xVector.dy) > 0.000_001,
              hypot(yVector.dx, yVector.dy) > 0.000_001 else {
            return nil
        }
        let margin = 0.08
        let offsets = fieldCornerOffsets(xVector: xVector, yVector: yVector)
        guard let fittedCenter = fitFieldCenter(
            preferredCenter: center,
            offsets: offsets,
            margin: margin
        ) else {
            return nil
        }
        let corners = offsets.map {
            CGPoint(x: fittedCenter.x + $0.dx, y: fittedCenter.y + $0.dy)
        }
        guard corners.allSatisfy({ pointInsideCameraBounds($0, margin: margin) }) else { return nil }
        return visualFieldRectangleCornersFromCurrentBounds(manualFieldPoints(cameraCorners: corners))
    }

    func manualFieldPoints(cameraCorners: [CGPoint]) -> [ManualFiducialPoint] {
        cameraCorners.enumerated().map { index, cameraPoint in
            ManualFiducialPoint(
                id: index + 1,
                point: CGPoint(x: cameraPoint.x, y: 1.0 - cameraPoint.y),
                cameraPoint: cameraPoint
            )
        }
    }

    func orderedManualFieldCorners(_ corners: [ManualFiducialPoint]) -> [ManualFiducialPoint] {
        Array(corners.sorted { $0.id < $1.id }.prefix(4))
    }
}

private func fieldCornerOffsets(
    xVector: CGVector,
    yVector: CGVector
) -> [CGVector] {
    let halfX = CGVector(dx: xVector.dx * 0.5, dy: xVector.dy * 0.5)
    let halfY = CGVector(dx: yVector.dx * 0.5, dy: yVector.dy * 0.5)
    return [
        CGVector(dx: -halfX.dx - halfY.dx, dy: -halfX.dy - halfY.dy),
        CGVector(dx: halfX.dx - halfY.dx, dy: halfX.dy - halfY.dy),
        CGVector(dx: halfX.dx + halfY.dx, dy: halfX.dy + halfY.dy),
        CGVector(dx: -halfX.dx + halfY.dx, dy: -halfX.dy + halfY.dy)
    ]
}

private func fitFieldCenter(
    preferredCenter: CGPoint,
    offsets: [CGVector],
    margin: Double
) -> CGPoint? {
    guard let minOffsetX = offsets.map(\.dx).min(),
          let maxOffsetX = offsets.map(\.dx).max(),
          let minOffsetY = offsets.map(\.dy).min(),
          let maxOffsetY = offsets.map(\.dy).max() else {
        return nil
    }
    let minCenterX = CGFloat(margin) - minOffsetX
    let maxCenterX = CGFloat(1.0 - margin) - maxOffsetX
    let minCenterY = CGFloat(margin) - minOffsetY
    let maxCenterY = CGFloat(1.0 - margin) - maxOffsetY
    guard minCenterX <= maxCenterX, minCenterY <= maxCenterY else { return nil }
    return CGPoint(
        x: min(max(preferredCenter.x, minCenterX), maxCenterX),
        y: min(max(preferredCenter.y, minCenterY), maxCenterY)
    )
}

private func pointInsideCameraBounds(_ point: CGPoint, margin: Double) -> Bool {
    Double(point.x) >= margin
        && Double(point.x) <= 1.0 - margin
        && Double(point.y) >= margin
        && Double(point.y) <= 1.0 - margin
}
