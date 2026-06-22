import Foundation

struct DrawVerifyCapability: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
}

enum DrawVerifyCoordinator {
    static let capabilities: [DrawVerifyCapability] = [
        DrawVerifyCapability(
            id: "center_crosshair",
            title: "Center Crosshair",
            detail: "Center mark and coordinate axes",
            systemImage: "scope"
        ),
        DrawVerifyCapability(
            id: "line_length",
            title: "Line Length",
            detail: "Horizontal and vertical measured lines",
            systemImage: "ruler"
        ),
        DrawVerifyCapability(
            id: "square_closure",
            title: "Square Closure",
            detail: "Closed square path for residual inspection",
            systemImage: "square"
        ),
        DrawVerifyCapability(
            id: "triangle",
            title: "Triangle",
            detail: "Three-edge shape sanity check",
            systemImage: "triangle"
        ),
        DrawVerifyCapability(
            id: "multi_shape_coordinate_sheet",
            title: "Coordinate Sheet",
            detail: "Multiple marks with coordinate labels",
            systemImage: "map"
        )
    ]

    static func title(for kind: String) -> String {
        capabilities.first { $0.id == kind }?.title ?? kind
    }

    static func request(
        kind: String,
        requestId: String,
        drawFeedMmMin: Double,
        expectedPlanHash: String? = nil
    ) -> BridgeCapabilityTestRequest {
        BridgeCapabilityTestRequest(
            requestId: requestId,
            kind: kind,
            frame: nil,
            includeHoming: false,
            drawFeedMmMin: drawFeedMmMin,
            travelFeedMmMin: 500.0,
            maxSegmentMm: 25.0,
            expectedPlanHash: expectedPlanHash
        )
    }

    static func shortPlanHash(_ hash: String) -> String {
        guard !hash.isEmpty else { return "--" }
        return String(hash.prefix(8))
    }
}
