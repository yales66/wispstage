import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct CropTests {
    private let window = CGRect(x: 200, y: 100, width: 400, height: 300)

    @Test func elementFrameBecomesWindowPixelsPlusMargin() {
        let r = Crop.pixelRect(element: CGRect(x: 210, y: 130, width: 40, height: 20), window: window,
                               imageSize: CGSize(width: 800, height: 600), margin: 8)
        #expect(r == CGRect(x: 4, y: 44, width: 112, height: 72))
    }

    @Test func scaleFollowsScreenshotToWindowRatio() {
        let r = Crop.pixelRect(element: CGRect(x: 210, y: 130, width: 40, height: 20), window: window,
                               imageSize: CGSize(width: 400, height: 300), margin: 0)
        #expect(r == CGRect(x: 10, y: 30, width: 40, height: 20))
    }

    @Test func partOutsideScreenshotIsClipped() {
        let r = Crop.pixelRect(element: CGRect(x: 580, y: 90, width: 60, height: 20), window: window,
                               imageSize: CGSize(width: 800, height: 600), margin: 8)
        #expect(r == CGRect(x: 744, y: 0, width: 56, height: 36))
    }

    @Test func elementEntirelyOutsideWindowYieldsNoRect() {
        #expect(Crop.pixelRect(element: CGRect(x: 0, y: 0, width: 50, height: 20), window: window,
                               imageSize: CGSize(width: 800, height: 600), margin: 8) == nil)
    }

    @Test(arguments: [
        ("toolbar.save", nil, "05-detail-toolbar.save"),
        (nil, "Saved", "05-detail-Saved"),
        (nil, "一段很长很长很长很长很长很长很长的文字", "05-detail-一段很长很长很长很长很长很长很长"),
        ("list.row.a/b", "x", "05-detail-list.row.a-b"),
    ] as [(String?, String?, String)])
    func cropFileNameUsesIdentifierElseText(id: String?, text: String?, name: String) {
        #expect(Crop.fileName(step: "05-detail", id: id, text: text) == name)
    }

    @Test func croppedImageHasExpectedSize() throws {
        let img = try #require(RGBAImage(width: 20, height: 10, fill: (10, 20, 30, 255)).cgImage)
        let cut = try #require(Crop.crop(img, to: CGRect(x: 2, y: 3, width: 5, height: 4)))
        #expect(cut.width == 5 && cut.height == 4)
    }
}
