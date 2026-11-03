import SwiftUI
import AppKit

struct QixuBrandMark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().accessibilityLabel("Qixu")
        } else {
            Image(systemName: "line.3.horizontal.decrease").resizable().scaledToFit().foregroundStyle(.orange).accessibilityLabel("Qixu")
        }
    }
}
