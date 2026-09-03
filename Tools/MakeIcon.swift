// Draws Stein's app icon and writes AppIcon.icns.
//
// Run by build.sh only when the icon is missing. The icon exists mainly so the
// entry in System Settings > Privacy & Security > Accessibility is recognisable -
// a status-bar app never shows one in the Dock.
//
// Deliberately CoreGraphics and ImageIO only, with no AppKit. This runs from a
// shell on a CI machine with no logged-in GUI session, and AppKit's image
// encoders are a poor bet in that situation. It also reports every failure
// instead of skipping it: the first version silently dropped any size it could
// not draw and left iconutil to fail on the remains, which reports nothing more
// useful than "Failed to generate ICNS".
import CoreGraphics
import Foundation
import ImageIO

/// Exactly the point sizes `iconutil` recognises. It accepts
/// icon_{16,32,128,256,512}x... with an optional @2x and rejects an iconset
/// containing any other name, so 64 and 1024 are rendered as 32@2x and 512@2x
/// rather than under names of their own.
let sizes = [16, 32, 128, 256, 512]

let output = CommandLine.arguments.count > 1
  ? URL(fileURLWithPath: CommandLine.arguments[1])
  : URL(fileURLWithPath: "AppIcon.icns")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("MakeIcon: \(message)\n".utf8))
  exit(1)
}

func draw(size: Int) -> CGImage {
  let side = CGFloat(size)
  guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
    fail("no sRGB colour space")
  }
  guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    fail("could not create a \(size)x\(size) bitmap context")
  }

  let inset = side * 0.06
  let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
  let radius = plate.width * 0.22

  // Stone: a cool grey slab, lit from the top.
  let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
  context.saveGState()
  context.addPath(path)
  context.clip()
  let colors = [
    CGColor(red: 0.32, green: 0.34, blue: 0.38, alpha: 1),
    CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1)
  ]
  if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: plate.midX, y: plate.maxY),
      end: CGPoint(x: plate.midX, y: plate.minY),
      options: []
    )
  }
  context.restoreGState()

  // Three windows, seated: two stacked on the left, one full-height on the right.
  let field = plate.insetBy(dx: plate.width * 0.16, dy: plate.height * 0.20)
  let gap = field.width * 0.07
  let leftWidth = (field.width - gap) * 0.46
  let rightWidth = field.width - gap - leftWidth
  let leftHeight = (field.height - gap) / 2

  let windows = [
    CGRect(x: field.minX, y: field.midY + gap / 2, width: leftWidth, height: leftHeight),
    CGRect(x: field.minX, y: field.minY, width: leftWidth, height: leftHeight),
    CGRect(x: field.maxX - rightWidth, y: field.minY, width: rightWidth, height: field.height)
  ]
  let alphas: [CGFloat] = [0.95, 0.72, 0.86]
  for (rect, alpha) in zip(windows, alphas) {
    let corner = min(rect.width, rect.height) * 0.16
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    )
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fillPath()
  }

  guard let image = context.makeImage() else {
    fail("could not read back the \(size)x\(size) bitmap")
  }
  return image
}

func writePNG(_ image: CGImage, to url: URL) {
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    "public.png" as CFString,
    1,
    nil
  ) else {
    fail("could not create a PNG writer for \(url.lastPathComponent)")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fail("could not write \(url.lastPathComponent)")
  }
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("Stein-\(UUID().uuidString).iconset")
do {
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
  fail("could not create \(iconset.path): \(error.localizedDescription)")
}

for size in sizes {
  writePNG(draw(size: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
  // iconutil wants icon_NxN@2x.png to hold double the pixels.
  writePNG(draw(size: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// iconutil will not create the output's directory, and reports a missing one with
// the same "Failed to generate ICNS" it uses for a malformed iconset. A fresh
// clone has no Resources/ directory at all - the only thing in it is the icon
// this tool generates, which is gitignored, so git has nothing there to check
// out. That made the assemble step fail for everyone except a machine that had
// already built once.
let directory = output.deletingLastPathComponent()
do {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
} catch {
  fail("could not create \(directory.path): \(error.localizedDescription)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
do {
  try process.run()
} catch {
  fail("could not run iconutil: \(error.localizedDescription)")
}
process.waitUntilExit()

guard process.terminationStatus == 0 else {
  // iconutil says only "Failed to generate ICNS", so say what it was given.
  let contents = (try? FileManager.default.contentsOfDirectory(atPath: iconset.path)) ?? []
  let described = contents.sorted().map { name -> String in
    let path = iconset.appendingPathComponent(name).path
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? -1
    return "    \(name) (\(size) bytes)"
  }
  fail("""
    iconutil exited \(process.terminationStatus). It was given \(contents.count) files in
    \(iconset.path):
    \(described.joined(separator: "\n"))
    """)
}

try? FileManager.default.removeItem(at: iconset)
