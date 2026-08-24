import SwiftUI

struct PixelRobot: View {
    var rendered = false

    private static let robotColor = Theme.robotOrange
    private static let eyeColor = Theme.textPrimary
    private static let grid: [[Int]] = [
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,0,1,0,0,0,0,1,0,1,0,0,0],
        [0,0,0,1,0,1,0,0,0,0,1,0,1,0,0,0],
    ]
    private static let sourceEyes: [(Int, Int)] = [
        (4,2), (4,3), (11,2), (11,3),
    ]
    private static let renderedEyes: [(Int, Int)] = [
        // A compact 3×3 pixel `>` and `<`, inside the same original body.
        (5,1), (4,2), (5,2), (5,3),
        (10,1), (10,2), (11,2), (10,3),
    ]

    var body: some View {
        let eyes = rendered ? Self.renderedEyes : Self.sourceEyes
        Canvas { context, size in
            let gridW = Self.grid[0].count
            let gridH = Self.grid.count
            let unit = min(size.width / CGFloat(gridW), size.height / CGFloat(gridH))
            let ox = (size.width - CGFloat(gridW) * unit) / 2
            let oy = (size.height - CGFloat(gridH) * unit) / 2
            var robotPath = Path()
            var eyePath = Path()
            for (y, row) in Self.grid.enumerated() {
                for (x, cell) in row.enumerated() where cell == 1 {
                    let rect = CGRect(
                        x: ox + CGFloat(x) * unit,
                        y: oy + CGFloat(y) * unit,
                        width: unit,
                        height: unit
                    )
                    robotPath.addRect(rect)
                }
            }
            for (x, y) in eyes {
                eyePath.addRect(CGRect(
                    x: ox + CGFloat(x) * unit,
                    y: oy + CGFloat(y) * unit,
                    width: unit,
                    height: unit
                ))
            }
            context.fill(robotPath, with: .color(Self.robotColor))
            context.fill(eyePath, with: .color(Self.eyeColor))
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityLabel(rendered ? "rendered markdown mode" : "source markdown mode")
    }
}
struct PixelWordmark: View {
    private let word = "opencode"
    private let glyphs: [Character: [String]] = [
        "o": ["01110","10001","10001","10001","10001","10001","01110"],
        "p": ["11110","10001","10001","11110","10000","10000","10000"],
        "e": ["11111","10000","10000","11110","10000","10000","11111"],
        "n": ["10001","11001","11001","10101","10011","10011","10001"],
        "c": ["01111","10000","10000","10000","10000","10000","01111"],
        "d": ["11110","10001","10001","10001","10001","10001","11110"]
    ]

    var body: some View {
        Canvas { context, size in
            let columns = word.count * 6 - 1
            let unit = min(size.width / CGFloat(columns), size.height / 9)
            let width = CGFloat(columns) * unit
            let ox = (size.width - width) / 2
            let oy = (size.height - unit * 9) / 2
            for (index, character) in word.enumerated() {
                guard let rows = glyphs[character] else { continue }
                for (y, row) in rows.enumerated() {
                    for (x, bit) in row.enumerated() where bit == "1" {
                        let px = ox + CGFloat(index * 6 + x) * unit
                        let py = oy + CGFloat(y) * unit
                        context.fill(Path(CGRect(x: px, y: py, width: unit, height: unit)), with: .color(Theme.textPrimary))
                        if y >= 5 {
                            context.fill(Path(CGRect(x: px, y: py + unit * 0.55, width: unit, height: unit * 0.18)), with: .color(Theme.textMuted))
                        }
                    }
                }
            }
        }
        .aspectRatio(41 / 9, contentMode: .fit)
        .accessibilityLabel("provider API keys")
    }
}

struct PixelArrow: View {
    enum Direction { case up, down }
    let direction: Direction
    var color: Color = Theme.textMuted

    private static let upGrid: [[Int]] = [
        [0,0,1,0,0],
        [0,1,1,1,0],
        [1,1,1,1,1],
        [0,1,1,1,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,0,0,0,0],
    ]

    private static let downGrid: [[Int]] = [
        [0,0,0,0,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
        [0,1,1,1,0],
        [1,1,1,1,1],
        [0,1,1,1,0],
        [0,0,1,0,0],
    ]

    var body: some View {
        let grid = direction == .up ? Self.upGrid : Self.downGrid
        Canvas { context, size in
            let cols = grid[0].count
            let rows = grid.count
            let unit = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            let ox = (size.width - CGFloat(cols) * unit) / 2
            let oy = (size.height - CGFloat(rows) * unit) / 2
            var path = Path()
            for (y, row) in grid.enumerated() {
                for (x, cell) in row.enumerated() where cell == 1 {
                    path.addRect(CGRect(x: ox + CGFloat(x) * unit, y: oy + CGFloat(y) * unit, width: unit, height: unit))
                }
            }
            context.fill(path, with: .color(color))
        }
        .aspectRatio(5 / 9, contentMode: .fit)
        .accessibilityLabel(direction == .up ? "scroll to top" : "scroll to bottom")
    }
}
