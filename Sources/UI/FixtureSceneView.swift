import SwiftUI
import SceneKit
import AppKit

/// A SceneKit view of a fixture with mouse orbit / zoom / pan.
struct FixtureSceneView: NSViewRepresentable {
    let scene: SCNScene
    /// Bumped to put the camera back on the fixture.
    var resetToken: Int
    /// The 3D background follows the app's light/dark appearance.
    @Environment(\.colorScheme) private var colorScheme

    private var background: NSColor {
        colorScheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }

    final class Coordinator { var lastToken = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = background
        view.defaultCameraController.interactionMode = .orbitTurntable
        Self.frameCamera(in: view)
        context.coordinator.lastToken = resetToken
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.backgroundColor = background
        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            Self.frameCamera(in: view)
        }
    }

    /// Looks at the whole fixture from a three-quarter view above.
    private static func frameCamera(in view: SCNView) {
        guard let scene = view.scene else { return }
        let (center, radius) = GDTFScene.framing(of: scene)
        let cameraNode: SCNNode
        if let existing = scene.rootNode.childNode(withName: "fixtureCamera", recursively: false) {
            cameraNode = existing
        } else {
            cameraNode = SCNNode()
            cameraNode.name = "fixtureCamera"
            cameraNode.camera = SCNCamera()
            scene.rootNode.addChildNode(cameraNode)
        }
        cameraNode.camera?.zNear = Double(radius) * 0.01
        cameraNode.camera?.zFar = Double(radius) * 60
        let distance = radius * 2.6
        cameraNode.position = SCNVector3(center.x + distance * 0.7, center.y + distance * 0.3, center.z + distance * 0.7)
        cameraNode.look(at: center)
        view.pointOfView = cameraNode
        view.defaultCameraController.target = center
        view.defaultCameraController.clearRoll()
    }
}

/// Carries a SceneKit scene out of a background task (it's only touched on the main actor afterwards).
private struct SceneBox: @unchecked Sendable {
    let built: GDTFScene.Built?
}

/// The 3D tab of the fixture editor: builds the scene from the GDTF on first view.
struct FixtureSceneTab: View {
    /// Resolves the .gdtf on local disk (copied out first if the Source isn't local), plus a temp dir to delete.
    let resolveLocal: () async -> (URL?, URL?)
    /// description.xml of the GDTF.
    let xmlData: Data

    private enum Phase {
        case loading
        case ready(GDTFScene.Built)
        case unavailable
    }

    @State private var phase: Phase = .loading
    @State private var resetToken = 0

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("3Dモデルを読み込み中...").font(.callout).foregroundStyle(.secondary)
                }
            case .unavailable:
                VStack(spacing: 6) {
                    Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.secondary)
                    Text("3Dプレビューできる形状がありません").foregroundStyle(.secondary)
                    Text("このGDTFにはジオメトリ(Geometries)の定義、または読み込める3Dモデル(.glb / .3ds)がありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .ready(let built):
                FixtureSceneView(scene: built.scene, resetToken: resetToken)
                    .overlay(alignment: .topLeading) {
                        Text(built.summary)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            resetToken += 1
                        } label: {
                            Label("視点をリセット", systemImage: "arrow.counterclockwise")
                        }
                        .padding(10)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text("ドラッグで回転 ・ スクロールでズーム ・ 右ドラッグ/⌥ドラッグで移動\n機材は吊った向きで表示します(パン/チルトなどの動きは未対応)。暗い色は見やすさのため明るめに表示しています。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private func load() async {
        let (url, temp) = await resolveLocal()
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        guard let url else { phase = .unavailable; return }
        let data = xmlData
        let result = await Task.detached(priority: .userInitiated) { () -> SceneBox in
            guard let archive = ZipReader(url: url) else { return SceneBox(built: nil) }
            return SceneBox(built: GDTFScene.build(description: data, archive: archive))
        }.value
        if let built = result.built { phase = .ready(built) } else { phase = .unavailable }
    }
}
