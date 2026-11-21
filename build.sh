#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/PocketPad.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$ICONSET_DIR"

echo "==> Generating bespoke PocketPad icons..."
cat > "$BUILD_DIR/gen_icon.swift" << 'EOF'
import AppKit
import CoreGraphics

func drawIcon(size: Int, outputPath: String) {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(1) }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Background rounded squircle
    let margin = s * 0.04
    let bgRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    let gradColors = [
        CGColor(red: 0.145, green: 0.157, blue: 0.180, alpha: 1.0),
        CGColor(red: 0.082, green: 0.088, blue: 0.102, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }

    // Trackpad glass surface (upper 60%)
    let padRect = CGRect(x: s * 0.14, y: s * 0.30, width: s * 0.72, height: s * 0.56)
    let padPath = CGPath(roundedRect: padRect, cornerWidth: s * 0.09, cornerHeight: s * 0.09, transform: nil)
    ctx.setFillColor(CGColor(red: 0.165, green: 0.178, blue: 0.205, alpha: 1.0))
    ctx.addPath(padPath)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1.5, s * 0.012))
    ctx.addPath(padPath)
    ctx.strokePath()

    // Sky-blue precision touch reticle
    let cx = s * 0.54
    let cy = s * 0.58
    let outerR = s * 0.13
    ctx.setFillColor(CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.18))
    ctx.fillEllipse(in: CGRect(x: cx - outerR, y: cy - outerR, width: outerR * 2, height: outerR * 2))

    ctx.setStrokeColor(CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.92))
    ctx.setLineWidth(max(1.8, s * 0.022))
    ctx.strokeEllipse(in: CGRect(x: cx - outerR * 0.72, y: cy - outerR * 0.72, width: outerR * 1.44, height: outerR * 1.44))

    let dotR = s * 0.032
    ctx.setFillColor(CGColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))

    // Split tactile keycaps at bottom
    let btnY = s * 0.14
    let btnH = s * 0.12
    let gap = s * 0.04
    let btnW = (s * 0.72 - gap) / 2
    for i in 0..<2 {
        let bx = s * 0.14 + CGFloat(i) * (btnW + gap)
        let bRect = CGRect(x: bx, y: btnY, width: btnW, height: btnH)
        let bPath = CGPath(roundedRect: bRect, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)
        ctx.setFillColor(CGColor(red: 0.20, green: 0.215, blue: 0.25, alpha: 1.0))
        ctx.addPath(bPath)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.11))
        ctx.setLineWidth(max(1, s * 0.008))
        ctx.addPath(bPath)
        ctx.strokePath()
    }

    guard let image = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: outputPath))
}

let args = CommandLine.arguments
let iconsetDir = args[1]
let resDir = args[2]

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (sz, name) in sizes {
    drawIcon(size: sz, outputPath: "\(iconsetDir)/\(name)")
}
drawIcon(size: 180, outputPath: "\(resDir)/apple-touch-icon.png")
EOF

swift "$BUILD_DIR/gen_icon.swift" "$ICONSET_DIR" "$RES_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"

echo "==> Compiling PocketPad native Swift binary..."
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework CryptoKit \
    -framework Network \
    -framework ApplicationServices \
    "$ROOT_DIR/Sources/NetworkUtils.swift" \
    "$ROOT_DIR/Sources/InputController.swift" \
    "$ROOT_DIR/Sources/WebSocketServer.swift" \
    "$ROOT_DIR/Sources/AppDelegate.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/PocketPad"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/index.html" "$RES_DIR/index.html"

echo "==> Ad-hoc signing PocketPad.app..."
codesign --force --deep --sign - "$APP_DIR"

DEST_DIR="${POCKETPAD_DEST_DIR:-}"
if [[ "${1:-}" == "--install" && -n "${2:-}" ]]; then
    DEST_DIR="$2"
fi

echo "==> Build complete:"
echo "    Build:   $APP_DIR"
if [[ -n "$DEST_DIR" ]]; then
    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_DIR/PocketPad.app"
    cp -R "$APP_DIR" "$DEST_DIR/PocketPad.app"
    echo "    Installed: $DEST_DIR/PocketPad.app"
fi
