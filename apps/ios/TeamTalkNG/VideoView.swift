import SwiftUI

/// Someone's camera, streamed video or shared desktop, as it arrives. The
/// picture is an image VoiceOver can describe (its image descriptions).
struct VideoView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let user: User
    let kind: VideoKind
    @State private var image: CGImage?
    @State private var size = (0, 0)

    private var what: String {
        switch kind {
        case .camera: "\(user.displayName)'s camera"
        case .mediaFile: "The video \(user.displayName) is streaming"
        case .desktop: "\(user.displayName)'s shared desktop"
        }
    }

    var body: some View {
        NavigationStack {
            VStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .accessibilityElement()
                        .accessibilityLabel(what)
                        .accessibilityValue("\(size.0) by \(size.1)")
                        .accessibilityAddTraits(.isImage)
                } else {
                    Text("Waiting for the picture…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(what)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                // A new picture a few times a second.
                while !Task.isCancelled {
                    if let f = connection.coreClient.videoFrame(userId: user.id, kind: kind) { show(f) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func show(_ f: VideoFrame) {
        let (w, h) = (Int(f.width), Int(f.height))
        guard w > 0, h > 0, f.bgra.count >= w * h * 4,
              let provider = CGDataProvider(data: Data(f.bgra) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        image = img
        size = (w, h)
    }
}
