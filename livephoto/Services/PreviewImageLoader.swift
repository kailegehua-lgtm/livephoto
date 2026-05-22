import SwiftUI

enum PreviewImageLoader {
    static func loadImage(from url: URL) -> Image? {
        guard
            let data = try? Data(contentsOf: url),
            let uiImage = UIImage(data: data)
        else {
            return nil
        }

        return Image(uiImage: uiImage)
    }
}
