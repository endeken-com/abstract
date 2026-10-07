import Foundation
import ImageIO
import Testing
import AbstractCore

@Suite("File paths in replies")
struct FilePathLinksTests {
    static let root = "/work/app"
    static let files: Set<String> = ["assets/logo.png", "src/main.swift", "README.md", "docs/a b.png"]

    static func link(_ text: String) -> String {
        FilePathLinks.link(text, root: root, files: files)
    }

    static func url(_ path: String, line: Int? = nil) -> String {
        FilePathLinks.url(.init(path: path, line: line)).absoluteString
    }

    @Test func inlineCodeBecomesALink() {
        #expect(Self.link("Saved to `assets/logo.png`.") == "Saved to [`assets/logo.png`](\(Self.url("assets/logo.png"))).")
    }

    @Test func aBareRelativePathBecomesALink() {
        #expect(Self.link("See assets/logo.png, then README.md.")
                == "See [assets/logo.png](\(Self.url("assets/logo.png"))), then [README.md](\(Self.url("README.md"))).")
        #expect(Self.link("(./src/main.swift)") == "([./src/main.swift](\(Self.url("src/main.swift"))))")
    }

    @Test func anAbsolutePathInsideTheWorktreeLinksToItsRelativePath() {
        #expect(Self.link("Wrote /work/app/assets/logo.png") == "Wrote [/work/app/assets/logo.png](\(Self.url("assets/logo.png")))")
        #expect(Self.link("`/work/app/src/main.swift:12`") == "[`/work/app/src/main.swift:12`](\(Self.url("src/main.swift", line: 12)))")
    }

    @Test func pathsOutsideTheWorktreeStayText() {
        for text in ["/work/other/assets/logo.png", "/work/application/README.md", "`../app/README.md`", "/etc/hosts", "~/assets/logo.png"] {
            #expect(Self.link(text) == text)
        }
    }

    @Test func missingFilesStayText() {
        for text in ["`assets/missing.png`", "assets/missing.png", "Done.", "e.g. this", "`swift test`", "version 1.2"] {
            #expect(Self.link(text) == text)
        }
    }

    @Test func codeBlocksLinksAndUrlsAreLeftAlone() {
        let text = """
        ```
        assets/logo.png
        ```
        [the logo](assets/logo.png) and <https://example.com/assets/logo.png> and https://example.com/README.md
        """
        #expect(Self.link(text) == text)
    }

    @Test func aLineNumberIsKept() {
        #expect(Self.link("src/main.swift:42:7") == "[src/main.swift:42:7](\(Self.url("src/main.swift", line: 42)))")
    }

    @Test func candidatesAreWhatToAskTheWorktreeAbout() {
        let text = "Made `assets/logo.png`, see src/main.swift:3 and /work/app/new.txt; ignore /tmp/x.png, `npm test` and http://x.io/a.png"
        #expect(FilePathLinks.candidates(in: text, root: Self.root) == ["assets/logo.png", "src/main.swift", "new.txt"])
    }

    @Test func urlsRoundTrip() throws {
        for target in [FilePathLinks.Target(path: "docs/a b.png"), .init(path: "src/(x)#1?.swift", line: 9)] {
            let url = FilePathLinks.url(target)
            #expect(!url.absoluteString.contains(where: { "() ".contains($0) }))
            #expect(FilePathLinks.target(url) == target)
        }
        #expect(FilePathLinks.target(URL(string: "https://example.com/a")!) == nil)
        #expect(Self.link("`docs/a b.png`") == "[`docs/a b.png`](\(Self.url("docs/a b.png")))")
    }
}

@Suite("Images by their bytes")
struct ImageFactsTests {
    static func png(width: Int, height: Int, alpha: Bool) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A 6 × 4 AVIF, encoded by ImageIO.
    static let avif = Data(base64Encoded: "AAAAIGZ0eXBhdmlmAAAAAE1pUHJhdmlmbWlhZm1pZjEAAAEhbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAAOcGl0bQAAAAAAAQAAACNpaW5mAAAAAAABAAAAFWluZmUCAAAAAAEAAGF2MDEAAAAAgWlwcnAAAABgaXBjbwAAABNjb2xybmNseAACAAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAAAGAAAABAAAAAlpcm90AAAAABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAVEAAAAkAAAAAW1kYXQAAAAAAAAANBIACgwAAAABDc//gQICBoQyEhABvgBJJJIgALALCJcddwZK4A==")!

    @Test func aPngIsAnImageWhateverItsName() throws {
        let facts = try #require(ImageFacts(try Self.png(width: 30, height: 20, alpha: true)))
        #expect(facts.type == "public.png")
        #expect(facts.dimensions == "30 × 20")
        #expect(facts.hasAlpha)
        #expect(ImageFacts(try Self.png(width: 2, height: 2, alpha: false))?.hasAlpha == false)
    }

    @Test func anAvifIsAnImage() throws {
        let facts = try #require(ImageFacts(Self.avif))
        #expect(facts.type == "public.avif")
        #expect(facts.width == 6 && facts.height == 4)
    }

    @Test func otherBytesAreNot() {
        #expect(ImageFacts(Data("just some text\n".utf8)) == nil)
        #expect(ImageFacts(Data([0, 1, 2, 3, 4, 5, 0xFF, 0xFE])) == nil)
        #expect(ImageFacts(Data()) == nil)
        #expect(ImageFacts(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil)
    }

    @Test func imageNames() {
        #expect(ImageFacts.isImageName("a/b.PNG"))
        #expect(ImageFacts.isImageName("shot.avif"))
        #expect(ImageFacts.isImageName("icon.svg"))
        #expect(ImageFacts.isImageName("doc.pdf"))
        #expect(!ImageFacts.isImageName("main.swift"))
        #expect(!ImageFacts.isImageName("logo"))
    }
}
