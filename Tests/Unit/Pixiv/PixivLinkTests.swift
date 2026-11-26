import XCTest

@testable import WallpaperMachine

final class PixivLinkTests: XCTestCase {
    func testParsesSupportedPixivArtworkURLFormats() {
        let cases: [(String, String)] = [
            ("https://www.pixiv.net/artworks/12345678", "12345678"),
            ("https://www.pixiv.net/artworks/12345678/", "12345678"),
            ("https://www.pixiv.net/artworks/12345678?ref=bookmark", "12345678"),
            ("https://pixiv.net/artworks/42", "42"),
            ("http://www.pixiv.net/artworks/98765432", "98765432"),
            ("https://www.pixiv.net/en/artworks/12345678", "12345678"),
            ("https://www.pixiv.net/en/artworks/12345678#1", "12345678"),
            ("https://www.pixiv.net/ja/artworks/12345678", "12345678"),
            ("https://www.pixiv.net/zh-cn/artworks/12345678", "12345678"),
            ("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=12345678", "12345678"),
            ("https://www.pixiv.net/member_illust.php?illust_id=54321&mode=medium", "54321"),
            ("pixiv.net/i/12345678", "12345678"),
            ("www.pixiv.net/i/12345678", "12345678"),
            ("https://pixiv.net/i/987654", "987654"),
            ("  https://www.pixiv.net/en/artworks/12345678 \n", "12345678"),
            ("https://WWW.PIXIV.NET/EN/ARTWORKS/00123456", "123456"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(PixivLink.illustID(in: input), expected, input)
            XCTAssertEqual(PixivLink.illustID(inLink: input), expected, input)
            XCTAssertFalse(PixivLink.isBareIllustID(input), "links are not bare ids: \(input)")
        }
    }

    func testParsesBareNumericIllustrationIDsOfAtLeastSixDigits() {
        XCTAssertEqual(PixivLink.illustID(in: "123456"), "123456")
        XCTAssertEqual(PixivLink.illustID(in: "  123456789012  "), "123456789012")
        XCTAssertEqual(PixivLink.illustID(in: "00123456"), "123456")
        XCTAssertTrue(PixivLink.isBareIllustID("123456"))
        XCTAssertTrue(PixivLink.isBareIllustID("  987654321 "))
        XCTAssertFalse(PixivLink.isBareIllustID("00123456"), "leading zeros are not canonical")
        XCTAssertNil(PixivLink.illustID(inLink: "123456"), "a bare id is not a link")
    }

    func testRejectsShortNumbersTagQueriesSentencesAndUntrustedURLs() {
        let rejected = [
            "",
            "   ",
            "0",
            "000000",
            "2026",
            "12345",
            "1234567890123",
            "1000users入り",
            "sky 12345678",
            "check https://www.pixiv.net/artworks/12345678",
            "１２３４５６",
            "https://www.pixiv.net/users/12345678",
            "https://www.pixiv.net/artworks/12345678/extra",
            "https://www.pixiv.net/artworks/abc",
            "https://www.pixiv.net/artworks/0",
            "https://www.pixiv.net/member_illust.php?mode=medium",
            "https://www.pixiv.net/member_illust.php?illust_id=abc",
            "https://evil.pixiv.net.example.com/artworks/12345678",
            "https://example.com/artworks/12345678",
            "ftp://www.pixiv.net/artworks/12345678",
            "https://user:pass@www.pixiv.net/artworks/12345678",
            "https://www.pixiv.net:8443/artworks/12345678",
            "https://www.pixiv.net/toolonglocale/artworks/12345678",
            "pixiv.net/users/12345678",
        ]
        for input in rejected {
            XCTAssertNil(PixivLink.illustID(in: input), "should reject: \(input)")
            XCTAssertFalse(PixivLink.isBareIllustID(input), "should not be bare id: \(input)")
        }
    }
}
