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

let pixelFormatL008: UInt32 = 0x4C30_3038          // 'L008' — kCVPixelFormatType_OneComponent8

func fail(_ why: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((why + "\n").utf8))
    exit(code)
}

/// The gain map's auxiliary data in the photo: Apple's (what every iPhone photo since iOS 14.1 has, and iOS 18+
/// photos still carry beside the newer kind), else — macOS 15+ — an ISO 21496-1 one.
func gainInfo(_ source: CGImageSource) -> (kind: String, type: CFString, info: [String: Any])? {
    if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
        as? [String: Any] {
        return ("apple", kCGImageAuxiliaryDataTypeHDRGainMap, info)
    }
    if #available(macOS 15.0, *),
       let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        as? [String: Any] {
        return ("iso", kCGImageAuxiliaryDataTypeISOGainMap, info)
    }
    return nil
}

func number(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

func fourCC(_ value: Any?) -> String {
    guard let n = (value as? NSNumber)?.uint32Value else { return "" }
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

func properties(_ source: CGImageSource) -> [String: Any] {
    (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
}

func read(_ photo: String, _ out: String) -> Never {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: photo) as CFURL, nil) else { fail("can't open the photo") }
    guard let (kind, _, info) = gainInfo(source) else { exit(3) }
    guard let data = info[kCGImageAuxiliaryDataInfoData as String] as? Data,
          let desc = info[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
          let width = number(desc["Width"]), let height = number(desc["Height"]), let row = number(desc["BytesPerRow"])
    else { fail("the gain map has no data that can be read") }
    let props = properties(source)
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail("can't write the gain map: \(error.localizedDescription)") }
    var format = fourCC(desc["PixelFormat"])
    if format.isEmpty, data.count >= row * height, row >= width, row < width * 2 { format = "L008" }   // not said: 8-bit grey by its size
    let answer: [String: Any] = ["type": kind, "width": width, "height": height, "bytesPerRow": row,
                                 "pixelFormat": format,
                                 "orientation": number(props[kCGImagePropertyOrientation as String]) ?? 1,
                                 "imageWidth": number(props[kCGImagePropertyPixelWidth as String]) ?? 0,
                                 "imageHeight": number(props[kCGImagePropertyPixelHeight as String]) ?? 0]
    guard let json = try? JSONSerialization.data(withJSONObject: answer), let line = String(data: json, encoding: .utf8)
    else { fail("can't describe the gain map") }
    print(line)
    exit(0)
}

/// The least a gain map's own metadata must say, for a photo whose original wouldn't hand its metadata over.
func plainGainMetadata() -> CGImageMetadata? {
    let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:HDRGainMap="http://ns.apple.com/HDRGainMap/1.0/" \
    HDRGainMap:HDRGainMapVersion="65536"/></rdf:RDF></x:xmpmeta>
    """
    return CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData)
}

func write(original: String, pixels: String, gain: String, gainWidth: Int, gainHeight: Int, out: String, quality: Double) -> Never {
    guard let origSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: original) as CFURL, nil) else { fail("can't open the original") }
    guard let (kind, auxType, origInfo) = gainInfo(origSource) else { fail("the original has no gain map", 3) }
    guard let pixelSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: pixels) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(pixelSource, 0, nil) else { fail("can't read the edited pixels") }
    guard gainWidth > 1, gainHeight > 1, let raw = try? Data(contentsOf: URL(fileURLWithPath: gain)),
          raw.count >= gainWidth * gainHeight else { fail("can't read the new gain map") }

    // The original's metadata — camera, date, GPS, and Apple's maker note, which holds the HDR headroom
    // ("33" and "48"; without them the photo looks flat) — as the new picture now is: upright, and its own size.
    var props = properties(origSource)
    let hadHeadroom = (props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["48"] != nil
    props[kCGImagePropertyOrientation as String] = 1
    if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        props[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        props[kCGImagePropertyExifDictionary as String] = exif
    }
    props.removeValue(forKey: kCGImagePropertyPixelWidth as String)        // the picture says its own size
    props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
    props[kCGImageDestinationLossyCompressionQuality as String] = quality

    // The gain map: the original's own dictionary (its metadata object as it came — it can't be rebuilt by
    // hand), with the new bytes and their size. Rows are padded to a multiple of four, as ImageIO expects;
    // an incomplete description is dropped without a word, hence every key here and the check at the end.
    let rowBytes = (gainWidth + 3) & ~3
    var padded = Data(capacity: rowBytes * gainHeight)
    let pad = Data(count: rowBytes - gainWidth)
    for y in 0..<gainHeight {
        padded.append(raw.subdata(in: (y * gainWidth)..<((y + 1) * gainWidth)))
        padded.append(pad)
    }
    var desc = (origInfo[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]) ?? [:]
    desc["Width"] = gainWidth
    desc["Height"] = gainHeight
    desc["BytesPerRow"] = rowBytes
    desc["PixelFormat"] = pixelFormatL008
    desc.removeValue(forKey: "Orientation")                                // the bytes are upright now
    var aux = origInfo
    aux[kCGImageAuxiliaryDataInfoData as String] = padded
    aux[kCGImageAuxiliaryDataInfoDataDescription as String] = desc
    if aux[kCGImageAuxiliaryDataInfoMetadata as String] == nil, kind == "apple", let plain = plainGainMetadata() {
        aux[kCGImageAuxiliaryDataInfoMetadata as String] = plain
    }

    let lower = out.lowercased()
    let type = (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ? "public.jpeg" : "public.heic") as CFString
    let url = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { fail("can't start the new photo") }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)          // the picture first…
    CGImageDestinationAddAuxiliaryDataInfo(dest, auxType, aux as CFDictionary)   // …then what belongs to it
    guard CGImageDestinationFinalize(dest) else {
        try? FileManager.default.removeItem(at: url)
        fail("the new photo couldn't be written")
    }
    // What was written must have its gain map (and its headroom, if the original had one), or it isn't HDR.
    guard let check = CGImageSourceCreateWithURL(url as CFURL, nil), gainInfo(check) != nil else {
        try? FileManager.default.removeItem(at: url)
        fail("the gain map didn't go into the new photo")
    }
    if hadHeadroom, (properties(check)[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["48"] == nil {
        try? FileManager.default.removeItem(at: url)
        fail("the HDR headroom didn't go into the new photo")
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
