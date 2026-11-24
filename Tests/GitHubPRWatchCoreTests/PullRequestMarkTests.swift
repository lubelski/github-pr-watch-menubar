import CoreGraphics
import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct PullRequestMarkTests {
    /// The menu bar style, moved by its offset, puts the edges of the rings and the tracks on
    /// half points, so they fall on whole pixels at 2×.
    @Test func menuBarEdgesLandOnTwoXPixels() {
        let style = PullRequestMark.Style.menuBar
        let offset = PullRequestMark.Style.menuBarOffset
        func onHalfPoint(_ value: CGFloat) -> Bool { abs((value * 2).rounded() - value * 2) < 0.001 }
        let ringEdges = [PullRequestMark.leftX, PullRequestMark.rightX].flatMap { x in
            [x - style.outerRadius, x - style.innerRadius, x + style.innerRadius, x + style.outerRadius].map { $0 + offset.x }
        }
        let trackEdges = [PullRequestMark.leftX, PullRequestMark.rightX].flatMap { x in
            [x - style.trackStroke / 2, x + style.trackStroke / 2].map { $0 + offset.x }
        }
        let armEdges = [PullRequestMark.topY - style.trackStroke / 2, PullRequestMark.topY + style.trackStroke / 2].map { $0 + offset.y }
        for edge in ringEdges + trackEdges + armEdges {
            #expect(onHalfPoint(edge), "edge at \(edge)")
        }
    }

    /// The arrowhead's tip stops short of the left track's top ring in both styles.
    @Test func arrowClearsTheLeftRing() {
        for style in [PullRequestMark.Style.large, .menuBar] {
            let right = PullRequestMark.rightTrack(style).boundingBoxOfPath
            #expect(right.minX > PullRequestMark.leftX + style.outerRadius)
        }
    }

    @Test func fittingCentersTheMark() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 100)
        let box = PullRequestMark.path(.large, fittedIn: rect).boundingBoxOfPath
        #expect(abs(box.height - 100) < 0.01)
        #expect(abs(box.midX - rect.midX) < 0.01)
        #expect(abs(box.midY - rect.midY) < 0.01)
    }

    @Test func iconJSONNamesEveryLayer() throws {
        for design in AppIconDrawing.Design.allCases {
            let json = try JSONSerialization.jsonObject(with: Data(AppIconDrawing.iconJSON(for: design).utf8)) as? [String: Any]
            let groups = try #require(json?["groups"] as? [[String: Any]])
            let names = (groups.first?["layers"] as? [[String: Any]])?.compactMap { $0["image-name"] as? String }
            #expect(names == design.layers.map { "\($0.name).png" })
        }
    }
}
