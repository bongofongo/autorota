import SwiftUI

enum AppFont {
    static var display: Font { .system(.largeTitle, design: .rounded, weight: .bold) }
    static var title: Font { .system(.title2, design: .rounded, weight: .semibold) }
    static var headline: Font { .headline }
    static var body: Font { .body }
    static var caption: Font { .caption }
    static var monoSmall: Font { .system(.caption, design: .monospaced) }
}
