import AppKit

final class SDRChart: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1).setFill()
        bounds.fill()
        let steps = 11
        let width = bounds.width / CGFloat(steps)
        for i in 0..<steps {
            let v = CGFloat(i) / CGFloat(steps - 1)
            NSColor(srgbRed: v, green: v, blue: v, alpha: 1).setFill()
            NSRect(x: CGFloat(i) * width, y: bounds.height / 2, width: width + 0.5, height: bounds.height / 2).fill()
            let label = "\(i * 10)%" as NSString
            label.draw(at: NSPoint(x: CGFloat(i) * width + 4, y: bounds.height / 2 + 6), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: i < 6 ? NSColor.white : NSColor.black])
        }
        let colors: [(CGFloat,CGFloat,CGFloat)] = [(1,0,0),(0,1,0),(0,0,1),(1,1,0),(0,1,1),(1,0,1)]
        let w = bounds.width / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            NSColor(srgbRed:c.0,green:c.1,blue:c.2,alpha:1).setFill()
            NSRect(x: CGFloat(i)*w, y: 0, width:w+0.5,height:bounds.height/2).fill()
        }
    }
}
