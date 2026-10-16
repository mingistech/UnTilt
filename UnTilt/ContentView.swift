import SwiftUI
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var photo: CGImage?
    @State private var sourceURL: URL?
    @State private var angle = 0.0
    @State private var targeted = false
    @State private var busy = false
    @State private var message = ""
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("UnTilt").font(.title2.bold())
                Spacer()
                if let sourceURL {
                    Text(sourceURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Open Photo…", action: openPhoto)
                    .keyboardShortcut("o")
            }
            .padding()

            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.9)
                    if let photo {
                        let available = CGSize(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 48))
                        let fit = min(available.width / CGFloat(photo.width), available.height / CGFloat(photo.height))
                        let size = CGSize(width: CGFloat(photo.width) * fit, height: CGFloat(photo.height) * fit)
                        Image(decorative: photo, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .rotationEffect(.degrees(angle))
                            .scaleEffect(PhotoRenderer.cropScale(width: Double(photo.width), height: Double(photo.height), degrees: angle))
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .overlay {
                                GridLines().stroke(.white.opacity(0.35), lineWidth: 0.5)
                                    .frame(width: size.width, height: size.height)
                                    .allowsHitTesting(false)
                            }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.badge.arrow.down").font(.system(size: 48, weight: .light))
                            Text("Drop a photo here").font(.title2)
                            Text("Straighten it. Save it. Done.").foregroundStyle(.gray)
                        }
                        .foregroundStyle(.white)
                    }
                    if targeted {
                        RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(8)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !busy, let url = urls.first, url.isFileURL else { return false }
                load(url)
                return true
            } isTargeted: { targeted = $0 }

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Image(systemName: "rotate.left")
                    Slider(value: $angle, in: -30...30, step: 0.05)
                        .accessibilityLabel("Rotation angle")
                    Image(systemName: "rotate.right")
                    Text(String(format: "%+.2f°", angle))
                        .monospacedDigit().frame(width: 72, alignment: .trailing)
                    Button("Reset") { angle = 0 }
                    Button(action: exportPhoto) {
                        if busy { ProgressView().controlSize(.small) }
                        else { Text("Done").frame(minWidth: 44) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(photo == nil || busy)
                HStack {
                    Text(message.isEmpty ? "Edges are cropped automatically. Your original stays untouched." : message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let savedURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 440)
        .disabled(busy)
        .alert("Couldn’t finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func openPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.tiff.identifier].contains(type as String),
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            errorMessage = "Choose a JPEG, PNG, HEIC, or TIFF photo that can be opened."
            return
        }
        photo = cgImage
        sourceURL = url
        angle = 0
        savedURL = nil
        message = ""
    }

    private func exportPhoto() {
        guard let photo, let sourceURL else { return }
        let folder = sourceURL.deletingLastPathComponent()
        var grantedFolder = folder
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            let panel = NSOpenPanel()
            panel.title = "Allow UnTilt to save beside your photo"
            panel.message = "Choose \(folder.lastPathComponent) to save the straightened copy in the original folder."
            panel.prompt = "Allow Saving"
            panel.directoryURL = folder
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            guard selected.standardizedFileURL.resolvingSymlinksInPath() == folder.standardizedFileURL.resolvingSymlinksInPath() else {
                errorMessage = "Please select the original folder: \(folder.path)"
                return
            }
            grantedFolder = selected
        }
        let access = grantedFolder.startAccessingSecurityScopedResource()
        let degrees = angle
        let ext = sourceURL.pathExtension.lowercased()
        let type: String
        switch ext {
        case "png": type = UTType.png.identifier
        case "heic", "heif": type = UTType.heic.identifier
        case "tif", "tiff": type = UTType.tiff.identifier
        default: type = UTType.jpeg.identifier
        }
        busy = true
        message = "Saving…"
        Task {
            defer {
                busy = false
                if access { grantedFolder.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PhotoRenderer.render(photo, degrees: degrees, type: type)
                }.value
                let stem = sourceURL.deletingPathExtension().lastPathComponent + "_UnTilted"
                var index = 0
                var output: URL
                // Exclusive creation also protects against another process creating the same name.
                while true {
                    let name = stem + (index == 0 ? "" : "_\(index + 1)")
                    output = grantedFolder.appendingPathComponent(name).appendingPathExtension(ext)
                    do {
                        try data.write(to: output, options: .withoutOverwriting)
                        break
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        index += 1
                    }
                }
                savedURL = output
                message = "Saved \(output.lastPathComponent)"
            } catch {
                message = ""
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for step in 1..<6 {
                let fraction = CGFloat(step) / 6
                path.move(to: CGPoint(x: rect.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
                path.move(to: CGPoint(x: 0, y: rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
            }
        }
    }
}

private enum PhotoRenderer {
    nonisolated static func cropScale(width: Double, height: Double, degrees: Double) -> Double {
        let radians = abs(degrees) * .pi / 180
        return cos(radians) + sin(radians) * max(width / height, height / width)
    }

    nonisolated static func render(_ image: CGImage, degrees: Double, type: String) throws -> Data {
        let width = Double(image.width)
        let height = Double(image.height)
        let scale = cropScale(width: width, height: height, degrees: degrees)
        let cropWidth = floor(width / scale)
        let cropHeight = floor(height / scale)
        // Core Image uses a bottom-left origin, opposite to the SwiftUI preview.
        let rotated = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: -width / 2, y: -height / 2))
            .transformed(by: CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .transformed(by: CGAffineTransform(translationX: cropWidth / 2, y: cropHeight / 2))
        let rect = CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)
        guard cropWidth >= 1, cropHeight >= 1,
              let output = CIContext().createCGImage(rotated, from: rect) else {
            throw NSError(domain: "UnTilt", code: 1, userInfo: [NSLocalizedDescriptionKey: "The straightened image could not be rendered."])
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw NSError(domain: "UnTilt", code: 2, userInfo: [NSLocalizedDescriptionKey: "This image format cannot be exported on this Mac."])
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "UnTilt", code: 3, userInfo: [NSLocalizedDescriptionKey: "The image could not be encoded."])
        }
        return data as Data
    }
}

#Preview {
    ContentView()
}
