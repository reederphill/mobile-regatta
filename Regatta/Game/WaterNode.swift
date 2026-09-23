import SpriteKit
import UIKit

/// A field of faint arrows showing which way the wind blows. The grid snaps to the
/// camera so it looks endless while only ever drawing one screen's worth of sprites.
final class WaterNode: SKNode {
    private let spacing: CGFloat = 96
    private let columns = 28
    private let rows = 32
    private var arrows: [SKSpriteNode] = []
    private var lastRotation: CGFloat = .nan

    override init() {
        super.init()
        let texture = SKTexture(image: WaterNode.arrowImage())
        for row in 0..<rows {
            for column in 0..<columns {
                let arrow = SKSpriteNode(texture: texture)
                arrow.alpha = 0.14
                let stagger = row.isMultiple(of: 2) ? 0 : spacing / 2
                arrow.position = CGPoint(
                    x: (CGFloat(column) - CGFloat(columns) / 2) * spacing + stagger,
                    y: (CGFloat(row) - CGFloat(rows) / 2) * rowHeight
                )
                addChild(arrow)
                arrows.append(arrow)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var rowHeight: CGFloat { spacing * 0.8 }

    func update(center: CGPoint, windDirection: Double) {
        // Snap to two rows so the stagger pattern lines up.
        let period = rowHeight * 2
        position = CGPoint(
            x: (center.x / spacing).rounded(.down) * spacing,
            y: (center.y / period).rounded(.down) * period
        )
        let rotation = CGFloat(-(windDirection + .pi))
        guard abs(rotation - lastRotation) > 0.002 || lastRotation.isNaN else { return }
        lastRotation = rotation
        for arrow in arrows { arrow.zRotation = rotation }
    }

    private static func arrowImage() -> UIImage {
        let size = CGSize(width: 20, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(2)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // Pointing up: the tip is at the top of the image.
            cg.move(to: CGPoint(x: 10, y: 28))
            cg.addLine(to: CGPoint(x: 10, y: 3))
            cg.move(to: CGPoint(x: 4, y: 10))
            cg.addLine(to: CGPoint(x: 10, y: 3))
            cg.addLine(to: CGPoint(x: 16, y: 10))
            cg.strokePath()
        }
    }
}
