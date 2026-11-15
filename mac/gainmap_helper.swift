/// Photo Browser for Mac's HDR gain-map helper — used by `gainmap.py`, which says why.
///
///     gainmap_helper read  <photo> <out.raw>
///     gainmap_helper write <original> <pixels.tiff> <gain.raw> <gain width> <gain height> <out.heic|.jpg> <quality 0…1>
///
/// **read** writes the photo's HDR gain map as its stored bytes (rows of `bytesPerRow`) and prints one line of
/// JSON: its kind, size, row length, pixel format, and the photo's EXIF orientation — the bytes are *as stored*,
/// the same way round as the photo's own stored pixels; Python turns both upright. Exit 3: no gain map.
///
/// **write** makes a new photo: the pixels from the TIFF (already upright, with the colour profile to keep),
/// the original's metadata (camera, date, GPS and Apple's maker note — which holds the HDR headroom — with the
/// orientation set to 1 and the pixel size corrected), and the gain map handed in (8-bit, any size, upright)
/// attached the way the original's was, with the original's own gain-map metadata. One encode: the pixels come
/// uncompressed, so the picture isn't compressed twice.
///
/// ImageIO only. Kept apart from the other helpers so that they go on building whatever happens here.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ why: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
    exit(code)
}

/// The gain map's auxiliary data in the photo: Apple's, else (macOS 15+) an ISO 21496-1 one.
func gainInfo(_ source: CGImageSource) -> (kind: String, type: CFString, info: [CFString: Any])? {
    if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
        as? [CFString: Any] {
        return ("apple", kCGImageAuxiliaryDataTypeHDRGainMap, info)
    }
    if #available(macOS 15.0, *),
       let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        as? [CFString: Any] {
        return ("iso", kCGImageAuxiliaryDataTypeISOGainMap, info)
    }
    return nil
}

func fourCC(_ value: Any?) -> String {
    guard let n = (value as? NSNumber)?.uint32Value else { return "" }
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

func read(_ photo: String, _ out: String) -> Never {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: photo) as CFURL, nil) else { fail("can't open the photo") }
    guard let (kind, _, info) = gainInfo(source) else { exit(3) }
    guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
          let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
          let width = (desc["Width"] as? NSNumber)?.intValue,
          let height = (desc["Height"] as? NSNumber)?.intValue,
          let row = (desc["BytesPerRow"] as? NSNumber)?.intValue
    else { fail("the gain map has no data") }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail("can't write the gain map: \(error.localizedDescription)") }
    let answer: [String: Any] = ["type": kind, "width": width, "height": height, "bytesPerRow": row,
                                 "pixelFormat": fourCC(desc["PixelFormat"]), "orientation": orientation,
                                 "imageWidth": (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                                 "imageHeight": (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0]
    guard let json = try? JSONSerialization.data(withJSONObject: answer), let line = String(data: json, encoding: .utf8)
    else { fail("can't describe the gain map") }
    print(line)
    exit(0)
}

func write(original: String, pixels: String, gain: String, gainWidth: Int, gainHeight: Int, out: String, quality: Double) -> Never {
    guard let origSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: original) as CFURL, nil) else { fail("can't open the original") }
    guard let (_, auxType, origInfo) = gainInfo(origSource) else { fail("the original has no gain map", 3) }
    guard let pixelSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: pixels) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(pixelSource, 0, nil) else { fail("can't read the edited pixels") }
    guard let gainData = try? Data(contentsOf: URL(fileURLWithPath: gain)), gainData.count >= gainWidth * gainHeight,
          gainWidth > 1, gainHeight > 1 else { fail("can't read the new gain map") }

    // The original's metadata, as the new picture now is: upright, and this size.
    var props = CGImageSourceCopyPropertiesAtIndex(origSource, 0, nil) as? [CFString: Any] ?? [:]
    props[kCGImagePropertyOrientation] = 1
    props[kCGImagePropertyPixelWidth] = image.width
    props[kCGImagePropertyPixelHeight] = image.height
    if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        props[kCGImagePropertyTIFFDictionary] = tiff
    }
    if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        props[kCGImagePropertyExifDictionary] = exif
    }
    props[kCGImageDestinationLossyCompressionQuality] = quality

    // The gain map: the original's description and metadata, with the new bytes and their size.
    var desc = origInfo[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any] ?? [:]
    desc["Width"] = gainWidth
    desc["Height"] = gainHeight
    desc["BytesPerRow"] = gainWidth
    desc.removeValue(forKey: "Orientation")
    var aux: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: gainData.prefix(gainWidth * gainHeight) as CFData,
                                kCGImageAuxiliaryDataInfoDataDescription: desc]
    if let meta = origInfo[kCGImageAuxiliaryDataInfoMetadata] {
        aux[kCGImageAuxiliaryDataInfoMetadata] = meta
    }

    let jpeg = out.lowercased().hasSuffix(".jpg") || out.lowercased().hasSuffix(".jpeg")
    let type = (jpeg ? UTType.jpeg : UTType.heic).identifier as CFString
    let url = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { fail("can't start the new photo") }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationAddAuxiliaryDataInfo(dest, auxType, aux as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        try? FileManager.default.removeItem(at: url)
        fail("the new photo couldn't be written")
    }
    // What was written must have its gain map, or it isn't what was asked for.
    guard let check = CGImageSourceCreateWithURL(url as CFURL, nil), gainInfo(check) != nil else {
        try? FileManager.default.removeItem(at: url)
        fail("the gain map didn't go into the new photo")
    }
    exit(0)
}

@main
struct GainMapHelper {
    static func main() {
        let a = CommandLine.arguments
        if a.count == 4, a[1] == "read" {
            read(a[2], a[3])
        }
        if a.count == 9, a[1] == "write", let gw = Int(a[5]), let gh = Int(a[6]), let q = Double(a[8]) {
            write(original: a[2], pixels: a[3], gain: a[4], gainWidth: gw, gainHeight: gh, out: a[7], quality: q)
        }
        fail("usage: gainmap_helper read <photo> <out.raw> | write <original> <pixels.tiff> <gain.raw> <w> <h> <out> <quality>", 2)
    }
}
