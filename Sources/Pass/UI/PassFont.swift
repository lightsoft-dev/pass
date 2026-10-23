import CoreText
import SwiftUI

enum PassFont {
    static func registerBundledFonts() {
        for face in ["Thin", "ExtraLight", "Light", "Regular", "Medium",
                     "SemiBold", "Bold", "ExtraBold", "Black"] {
            guard let url = Bundle.main.url(forResource: "Pretendard-\(face)", withExtension: "otf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .ultraLight: face = "ExtraLight"
        case .thin: face = "Thin"
        case .light: face = "Light"
        case .medium: face = "Medium"
        case .semibold: face = "SemiBold"
        case .bold: face = "Bold"
        case .heavy: face = "ExtraBold"
        case .black: face = "Black"
        default: face = "Regular"
        }
        return .custom("Pretendard-\(face)", size: size)
    }
}
