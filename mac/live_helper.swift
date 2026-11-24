// live_helper — writes a Live Photo's identifier into a photo's Apple maker note, with ImageIO.
//
//   live_helper image-id <photo> <output> <identifier>
//
// The photo is read and written again at <output> (never over itself) with `{MakerApple}` "17" set to the
// identifier, every other property carried across — the picture's own data is copied, not decoded and encoded
// again (CGImageDestinationAddImageFromSource). It is the iPhone app's `FileActions.writeAssetIdentifier`, so a
// photo given its identifier on the Mac is read by the iPhone exactly as one it made itself.
//
// Photo Browser for Mac (live_photo.py) builds this once with swiftc and calls it for photos it can't do itself
// (HEIC, TIFF, a JPEG that already has another camera's maker note); it then checks the output and puts it in the
// photo's place through its own undoable writer.

import Foundation
import ImageIO

@main
struct LiveHelper {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 5, args[1] == "image-id" else {
            FileHandle.standardError.write("usage: live_helper image-id <photo> <output> <identifier>\n".data(using: .utf8)!)
            exit(2)
        }
        let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3]), identifier = args[4]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src) else {
            FileHandle.standardError.write("can't read the photo\n".data(using: .utf8)!)
            exit(1)
        }
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type, max(count, 1), nil) else {
            FileHandle.standardError.write("can't write this kind of photo\n".data(using: .utf8)!)
            exit(1)
        }
        for index in 0..<max(count, 1) {
            var props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            if index == 0 {
                var maker = (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
                maker["17"] = identifier
                props[kCGImagePropertyMakerAppleDictionary] = maker
            }
            CGImageDestinationAddImageFromSource(dest, src, index, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: output)
            FileHandle.standardError.write("the photo couldn't be written\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
