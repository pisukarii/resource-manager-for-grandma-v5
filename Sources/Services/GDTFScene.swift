import Foundation
import SceneKit
import simd

/// Raw triangle mesh read from a model file, before it is fitted to the GDTF's declared size.
struct RawMesh {
    struct Part {
        var indices: [UInt32]
        var color: SIMD4<Float>?
    }
    var positions: [Float] = []     // x, y, z, x, y, z, ...
    var normals: [Float] = []       // same layout and count as `positions`
    var parts: [Part] = []

    var vertexCount: Int { positions.count / 3 }

    /// Smooth per-vertex normals for the vertices `range`, from the triangles `indices` (used when the file has none).
    mutating func computeNormals(for indices: [UInt32], range: Range<Int>) {
        var sums = [SIMD3<Float>](repeating: .zero, count: range.count)
        func p(_ i: Int) -> SIMD3<Float> { SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]) }
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard range.contains(a), range.contains(b), range.contains(c) else { continue }
            let n = simd_cross(p(b) - p(a), p(c) - p(a))      // area-weighted
            sums[a - range.lowerBound] += n
            sums[b - range.lowerBound] += n
            sums[c - range.lowerBound] += n
        }
        for (k, sum) in sums.enumerated() {
            let n = simd_length(sum) > 1e-12 ? simd_normalize(sum) : SIMD3<Float>(0, 0, 1)
            let v = (range.lowerBound + k) * 3
            normals[v] = n.x; normals[v + 1] = n.y; normals[v + 2] = n.z
        }
    }
}

// MARK: - Little-endian readers

private extension Data {
    func u16(_ o: Int) -> Int { Int(withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }) }
    func u32(_ o: Int) -> Int { Int(withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }) }
    func f32(_ o: Int) -> Float { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) } }
}

// MARK: - glTF binary (.glb)

enum GLBLoader {
    /// Triangle meshes of a .glb, with node transforms baked into the vertices. Nil for unsupported files (e.g. Draco).
    static func load(_ data: Data) -> RawMesh? {
        guard data.count > 20, data.u32(0) == 0x46546C67 else { return nil }     // "glTF"
        var json: [String: Any]?
        var bin: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let length = data.u32(offset), type = data.u32(offset + 4)
            let start = offset + 8, end = min(start + length, data.count)
            guard start <= end else { break }
            let chunk = data.subdata(in: start..<end)
            if type == 0x4E4F534A { json = (try? JSONSerialization.jsonObject(with: chunk)) as? [String: Any] }
            else if type == 0x004E4942, bin == nil { bin = chunk }
            offset = start + length
        }
        guard let json, let bin else { return nil }
        if let required = json["extensionsRequired"] as? [String], required.contains("KHR_draco_mesh_compression") { return nil }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let materials = json["materials"] as? [[String: Any]] ?? []

        func intValue(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

        /// `components` numbers per element, as Floats.
        func floats(_ accessorIndex: Int, components: Int) -> [Float]? {
            guard accessorIndex < accessors.count else { return nil }
            let a = accessors[accessorIndex]
            guard intValue(a["componentType"]) == 5126, let count = intValue(a["count"]),
                  let viewIndex = intValue(a["bufferView"]), viewIndex < views.count else { return nil }
            let v = views[viewIndex]
            let base = (intValue(v["byteOffset"]) ?? 0) + (intValue(a["byteOffset"]) ?? 0)
            let stride = intValue(v["byteStride"]) ?? components * 4
            guard count >= 0, base + (count > 0 ? (count - 1) * stride + components * 4 : 0) <= bin.count else { return nil }
            var out = [Float](); out.reserveCapacity(count * components)
            for i in 0..<count { for c in 0..<components { out.append(bin.f32(base + i * stride + c * 4)) } }
            return out
        }
        func indices(_ accessorIndex: Int) -> [UInt32]? {
            guard accessorIndex < accessors.count else { return nil }
            let a = accessors[accessorIndex]
            guard let type = intValue(a["componentType"]), let count = intValue(a["count"]),
                  let viewIndex = intValue(a["bufferView"]), viewIndex < views.count else { return nil }
            let size = type == 5121 ? 1 : (type == 5123 ? 2 : 4)
            guard [5121, 5123, 5125].contains(type) else { return nil }
            let v = views[viewIndex]
            let base = (intValue(v["byteOffset"]) ?? 0) + (intValue(a["byteOffset"]) ?? 0)
            let stride = intValue(v["byteStride"]) ?? size
            guard count >= 0, base + (count > 0 ? (count - 1) * stride + size : 0) <= bin.count else { return nil }
            return (0..<count).map { i in
                let o = base + i * stride
                switch size {
                case 1: return UInt32(bin[o])
                case 2: return UInt32(bin.u16(o))
                default: return UInt32(bin.u32(o))
                }
            }
        }

        func localMatrix(_ node: [String: Any]) -> simd_float4x4 {
            if let m = node["matrix"] as? [NSNumber], m.count == 16 {
                let f = m.map(\.floatValue)       // column-major
                return simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                               SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
            }
            var result = matrix_identity_float4x4
            if let t = node["translation"] as? [NSNumber], t.count == 3 {
                result.columns.3 = SIMD4(t[0].floatValue, t[1].floatValue, t[2].floatValue, 1)
            }
            if let r = node["rotation"] as? [NSNumber], r.count == 4 {
                let q = simd_quatf(ix: r[0].floatValue, iy: r[1].floatValue, iz: r[2].floatValue, r: r[3].floatValue)
                result = result * simd_float4x4(simd_normalize(q))
            }
            if let s = node["scale"] as? [NSNumber], s.count == 3 {
                result = result * simd_float4x4(diagonal: SIMD4(s[0].floatValue, s[1].floatValue, s[2].floatValue, 1))
            }
            return result
        }

        var mesh = RawMesh()

        func add(meshIndex: Int, world: simd_float4x4) {
            guard meshIndex < meshes.count else { return }
            let normalMatrix = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                             SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                             SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)).inverse.transpose
            for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
                guard (intValue(primitive["mode"]) ?? 4) == 4,
                      let attributes = primitive["attributes"] as? [String: Any],
                      let posIndex = intValue(attributes["POSITION"]),
                      let pos = floats(posIndex, components: 3) else { continue }
                let vertexCount = pos.count / 3
                let triangles = intValue(primitive["indices"]).flatMap(indices) ?? (0..<UInt32(vertexCount)).map { $0 }
                guard mesh.vertexCount + vertexCount < 3_000_000 else { return }
                let base = mesh.vertexCount

                for i in 0..<vertexCount {
                    let p = world * SIMD4(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2], 1)
                    mesh.positions += [p.x, p.y, p.z]
                }
                if let nIndex = intValue(attributes["NORMAL"]), let n = floats(nIndex, components: 3), n.count == pos.count {
                    for i in 0..<vertexCount {
                        let v = normalMatrix * SIMD3(n[i * 3], n[i * 3 + 1], n[i * 3 + 2])
                        let u = simd_length(v) > 1e-12 ? simd_normalize(v) : SIMD3<Float>(0, 0, 1)
                        mesh.normals += [u.x, u.y, u.z]
                    }
                } else {
                    mesh.normals += [Float](repeating: 0, count: vertexCount * 3)
                    let shifted = triangles.map { $0 + UInt32(base) }
                    mesh.computeNormals(for: shifted, range: base..<(base + vertexCount))
                }
                var color: SIMD4<Float>?
                if let m = intValue(primitive["material"]), m < materials.count,
                   let pbr = materials[m]["pbrMetallicRoughness"] as? [String: Any],
                   let f = pbr["baseColorFactor"] as? [NSNumber], f.count == 4 {
                    color = SIMD4(f[0].floatValue, f[1].floatValue, f[2].floatValue, f[3].floatValue)
                }
                mesh.parts.append(.init(indices: triangles.map { $0 + UInt32(base) }, color: color))
            }
        }

        func visit(_ index: Int, parent: simd_float4x4, depth: Int) {
            guard index < nodes.count, depth < 64 else { return }
            let node = nodes[index]
            let world = parent * localMatrix(node)
            if let m = intValue(node["mesh"]) { add(meshIndex: m, world: world) }
            for child in node["children"] as? [NSNumber] ?? [] { visit(child.intValue, parent: world, depth: depth + 1) }
        }

        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = intValue(json["scene"]) ?? 0
        let roots = (sceneIndex < scenes.count ? scenes[sceneIndex]["nodes"] as? [NSNumber] : nil)?.map(\.intValue)
            ?? Array(0..<nodes.count)
        for root in roots { visit(root, parent: matrix_identity_float4x4, depth: 0) }
        return mesh.parts.isEmpty ? nil : mesh
    }
}

// MARK: - 3D Studio (.3ds)

enum ThreeDSLoader {
    /// All triangle meshes of a .3ds (vertices as stored; the file's own units).
    static func load(_ data: Data) -> RawMesh? {
        guard data.count > 6, data.u16(0) == 0x4D4D else { return nil }
        var mesh = RawMesh()

        func walk(_ start: Int, _ end: Int, depth: Int) {
            var o = start
            while o + 6 <= end {
                let id = data.u16(o), length = data.u32(o + 2)
                guard length >= 6, o + length <= end else { return }
                let body = o + 6, chunkEnd = o + length
                switch id {
                case 0x3D3D, 0x4100:
                    if depth < 8 { walk(body, chunkEnd, depth: depth + 1) }
                case 0x4000:
                    var s = body
                    while s < chunkEnd, data[s] != 0 { s += 1 }       // object name
                    if depth < 8 { walk(s + 1, chunkEnd, depth: depth + 1) }
                case 0x4110:
                    guard body + 2 <= chunkEnd else { break }
                    let n = data.u16(body)
                    guard body + 2 + n * 12 <= chunkEnd else { break }
                    var v = [Float](); v.reserveCapacity(n * 3)
                    for i in 0..<(n * 3) { v.append(data.f32(body + 2 + i * 4)) }
                    // The faces chunk follows in the same mesh.
                    if let faces = findFaces(from: o + length, end: end) {
                        guard mesh.vertexCount + n < 3_000_000 else { return }
                        let base = mesh.vertexCount
                        mesh.positions += v
                        mesh.normals += [Float](repeating: 0, count: n * 3)
                        let triangles = faces.map { UInt32($0) + UInt32(base) }
                        mesh.computeNormals(for: triangles, range: base..<(base + n))
                        mesh.parts.append(.init(indices: triangles, color: nil))
                    }
                default:
                    break
                }
                o = chunkEnd
            }
        }

        /// Face indices (3 per triangle) from the next 0x4120 chunk at or after `from`.
        func findFaces(from: Int, end: Int) -> [Int]? {
            var o = from
            while o + 6 <= end {
                let id = data.u16(o), length = data.u32(o + 2)
                guard length >= 6, o + length <= end else { return nil }
                if id == 0x4120 {
                    let body = o + 6
                    guard body + 2 <= o + length else { return nil }
                    let n = data.u16(body)
                    guard body + 2 + n * 8 <= o + length else { return nil }
                    var out = [Int](); out.reserveCapacity(n * 3)
                    for i in 0..<n {
                        let f = body + 2 + i * 8
                        out += [data.u16(f), data.u16(f + 2), data.u16(f + 4)]
                    }
                    return out
                }
                o += length
            }
            return nil
        }

        walk(6, data.count, depth: 0)
        return mesh.parts.isEmpty ? nil : mesh
    }
}

// MARK: - GDTF -> SceneKit

/// Builds a SceneKit scene of a fixture from a GDTF: the geometry tree
/// (`Geometries`) placed with each geometry's `Position`, each one drawn with
/// its model — the .glb / .3ds in the archive when there is one, else the
/// GDTF's primitive shape (Cube, Cylinder, Base, Yoke, Head ...) at the
/// declared Length x Width x Height. The fixture hangs from the origin, the way
/// GDTF defines it (Z up).
enum GDTFScene {
    struct Built {
        let scene: SCNScene
        /// What was drawn, e.g. "3Dモデル 3点 + 基本形状 1点".
        let summary: String
        let fileModelCount: Int
        let primitiveCount: Int
    }

    static func build(description: Data, archive: ZipReader) -> Built? {
        guard let doc = try? XMLDocument(data: description, options: [.nodeLoadExternalEntitiesNever]),
              let geometries = (try? doc.nodes(forXPath: "//FixtureType/Geometries"))?.first as? XMLElement else { return nil }
        let builder = Builder(archive: archive, doc: doc)
        let root = SCNNode()
        for case let element as XMLElement in geometries.children ?? [] where Builder.isGeometry(element) {
            root.addChildNode(builder.node(for: element, depth: 0, modelOverride: nil))
        }
        guard !root.childNodes.isEmpty, builder.drawnCount > 0 else { return nil }
        // GDTF is Z-up; SceneKit is Y-up.
        let holder = SCNNode()
        holder.eulerAngles.x = -.pi / 2
        holder.addChildNode(root)
        let scene = SCNScene()
        scene.rootNode.addChildNode(holder)

        var parts: [String] = []
        if builder.fileModels > 0 { parts.append("3Dモデル \(builder.fileModels)点") }
        if builder.primitives > 0 { parts.append("基本形状 \(builder.primitives)点") }
        return Built(scene: scene, summary: parts.joined(separator: " + "),
                     fileModelCount: builder.fileModels, primitiveCount: builder.primitives)
    }

    /// Centre and radius of everything in the scene, from its bounding box (`boundingSphere` reports 0 for small fixtures).
    static func framing(of scene: SCNScene) -> (center: SCNVector3, radius: CGFloat) {
        let (lo, hi) = scene.rootNode.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        return (center, max((dx * dx + dy * dy + dz * dz).squareRoot() / 2, 0.02))
    }

    private struct ModelDef {
        let name: String, file: String, primitive: String
        let length: Float, width: Float, height: Float
    }

    private final class Builder {
        let archive: ZipReader
        var models: [String: ModelDef] = [:]
        var geometryByName: [String: XMLElement] = [:]
        var glb: [String: String] = [:]
        var threeDS: [String: String] = [:]
        var cache: [String: SCNNode] = [:]
        var nodeCount = 0
        var fileModels = 0
        var primitives = 0
        var drawnCount: Int { fileModels + primitives }
        private var loadedFiles: [String: RawMesh] = [:]
        private var counted = Set<String>()

        init(archive: ZipReader, doc: XMLDocument) {
            self.archive = archive
            for case let m as XMLElement in (try? doc.nodes(forXPath: "//FixtureType/Models/Model")) ?? [] {
                let def = ModelDef(
                    name: Self.attr(m, "Name"), file: Self.attr(m, "File"), primitive: Self.attr(m, "PrimitiveType"),
                    length: Float(Self.attr(m, "Length")) ?? 0, width: Float(Self.attr(m, "Width")) ?? 0,
                    height: Float(Self.attr(m, "Height")) ?? 0)
                models[def.name] = def
            }
            for case let g as XMLElement in (try? doc.nodes(forXPath: "//FixtureType/Geometries//*[@Name]")) ?? [] {
                let name = Self.attr(g, "Name")
                if geometryByName[name] == nil { geometryByName[name] = g }
            }
            for name in archive.names {
                let lower = name.lowercased()
                if lower.hasPrefix("models/gltf/"), lower.hasSuffix(".glb") { glb[Self.key(name)] = glb[Self.key(name)] ?? name }
                if lower.hasPrefix("models/3ds/"), lower.hasSuffix(".3ds") { threeDS[Self.key(name)] = threeDS[Self.key(name)] ?? name }
            }
        }

        static func attr(_ e: XMLElement, _ name: String) -> String { e.attribute(forName: name)?.stringValue ?? "" }

        /// ASCII letters and digits of the file's stem, lowercased: file names in a GDTF often come out
        /// differently encoded in the zip and in description.xml, but their ASCII part still matches.
        static func key(_ path: String) -> String {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return String(stem.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }

        static func isGeometry(_ e: XMLElement) -> Bool {
            guard e.name != "Break" else { return false }
            return e.attribute(forName: "Name") != nil && (e.attribute(forName: "Position") != nil || e.attribute(forName: "Model") != nil || e.childCount > 0)
        }

        /// "{r00,r01,r02,tx}{r10,...}{...}{0,0,0,1}" (rows, translation in the last column).
        static func matrix(_ text: String) -> simd_float4x4 {
            let v = text.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
                .replacingOccurrences(of: ",", with: " ").split(separator: " ").compactMap { Float($0) }
            guard v.count >= 12 else { return matrix_identity_float4x4 }
            return simd_float4x4(columns: (SIMD4(v[0], v[4], v[8], 0), SIMD4(v[1], v[5], v[9], 0),
                                           SIMD4(v[2], v[6], v[10], 0), SIMD4(v[3], v[7], v[11], 1)))
        }

        func node(for element: XMLElement, depth: Int, modelOverride: String?) -> SCNNode {
            let n = SCNNode()
            n.name = Self.attr(element, "Name")
            n.simdTransform = Self.matrix(Self.attr(element, "Position"))
            nodeCount += 1
            guard depth < 24, nodeCount < 5000 else { return n }

            if element.name == "GeometryReference",
               let target = geometryByName[Self.attr(element, "Geometry")] {
                // The reference supplies the position (and maybe a model); the shape comes from the geometry it points to.
                let own = Self.attr(element, "Model")
                let inner = node(for: target, depth: depth + 1, modelOverride: own.isEmpty ? nil : own)
                inner.simdTransform = matrix_identity_float4x4
                n.addChildNode(inner)
                return n
            }

            let modelName = modelOverride ?? Self.attr(element, "Model")
            if !modelName.isEmpty, let def = models[modelName],
               let shape = shapeNode(def, isBeam: element.name == "Beam") {
                n.addChildNode(shape.clone())
            }
            for case let child as XMLElement in element.children ?? [] where Self.isGeometry(child) {
                n.addChildNode(node(for: child, depth: depth + 1, modelOverride: nil))
            }
            return n
        }

        // MARK: Shapes

        private func shapeNode(_ def: ModelDef, isBeam: Bool) -> SCNNode? {
            let cacheKey = "\(def.name)|\(isBeam)"
            if let cached = cache[cacheKey] { return cached }
            var shape: SCNNode?
            var fromFile = false
            if !def.file.isEmpty, let geometry = fileGeometry(def) { shape = SCNNode(geometry: geometry); fromFile = true }
            if shape == nil { shape = primitiveNode(def) }
            guard let shape else { return nil }
            if isBeam { for m in shape.geometry?.materials ?? [] { m.emission.contents = NSColor(white: 0.85, alpha: 1) } }
            if counted.insert(def.name).inserted {      // each distinct model counts once
                if fromFile { fileModels += 1 } else { primitives += 1 }
            }
            shape.name = def.name
            cache[cacheKey] = shape
            return shape
        }

        private func fileGeometry(_ def: ModelDef) -> SCNGeometry? {
            let k = Self.key(def.file)
            guard !k.isEmpty else { return nil }
            var mesh: RawMesh?
            var yUp = false
            if let entry = glb[k] {
                mesh = loadedFiles[entry] ?? archive.read(entry).flatMap(GLBLoader.load)
                if let mesh { loadedFiles[entry] = mesh }
                yUp = true
            }
            if mesh == nil, let entry = threeDS[k] {
                mesh = loadedFiles[entry] ?? archive.read(entry).flatMap(ThreeDSLoader.load)
                if let mesh { loadedFiles[entry] = mesh }
                yUp = false
            }
            guard let mesh else { return nil }
            return Self.geometry(from: mesh, yUp: yUp, target: SIMD3(def.length, def.width, def.height))
        }

        /// Fits the mesh to the model's declared size (per axis, about the origin) and builds the SceneKit geometry.
        static func geometry(from mesh: RawMesh, yUp: Bool, target: SIMD3<Float>) -> SCNGeometry? {
            var pos = mesh.positions, nrm = mesh.normals
            let count = pos.count / 3
            guard count > 0 else { return nil }
            if yUp {   // glTF is Y-up, GDTF Z-up: (x, y, z) -> (x, -z, y)
                for i in 0..<count {
                    let (x, y, z) = (pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
                    pos[i * 3] = x; pos[i * 3 + 1] = -z; pos[i * 3 + 2] = y
                    let (nx, ny, nz) = (nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2])
                    nrm[i * 3] = nx; nrm[i * 3 + 1] = -nz; nrm[i * 3 + 2] = ny
                }
            }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in 0..<count {
                let p = SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            let size = hi - lo
            var scale = SIMD3<Float>(repeating: 1)
            for axis in 0..<3 where size[axis] > 1e-9 && target[axis] > 0 { scale[axis] = target[axis] / size[axis] }
            for i in 0..<count {
                pos[i * 3] *= scale.x; pos[i * 3 + 1] *= scale.y; pos[i * 3 + 2] *= scale.z
                let n = SIMD3(nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2]) / scale
                let u = simd_length(n) > 1e-12 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
                nrm[i * 3] = u.x; nrm[i * 3 + 1] = u.y; nrm[i * 3 + 2] = u.z
            }

            func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
                SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic,
                                  vectorCount: count, usesFloatComponents: true, componentsPerVector: 3,
                                  bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            }
            var elements: [SCNGeometryElement] = []
            var materials: [SCNMaterial] = []
            for part in mesh.parts {
                elements.append(SCNGeometryElement(indices: part.indices, primitiveType: .triangles))
                let color = part.color.map { NSColor(red: CGFloat($0.x), green: CGFloat($0.y), blue: CGFloat($0.z), alpha: 1) }
                materials.append(material(color))
            }
            let geometry = SCNGeometry(sources: [source(pos, .vertex), source(nrm, .normal)], elements: elements)
            geometry.materials = materials
            return geometry
        }

        static func material(_ color: NSColor?) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            // Real fixtures are often pure black, which vanishes on the dark preview background:
            // lift the colour's floor so the shape still reads (the highlights do the rest).
            let shown = color.map { c -> NSColor in
                let rgb = c.usingColorSpace(.sRGB) ?? c
                return NSColor(red: 0.30 + 0.70 * rgb.redComponent, green: 0.30 + 0.70 * rgb.greenComponent,
                               blue: 0.30 + 0.70 * rgb.blueComponent, alpha: 1)
            }
            m.diffuse.contents = shown ?? NSColor(white: 0.55, alpha: 1)
            m.specular.contents = NSColor(white: 0.45, alpha: 1)
            m.shininess = 0.35
            m.isDoubleSided = true      // face winding differs between exporters
            return m
        }

        /// GDTF primitive types, centred on the origin and sized Length (x) x Width (y) x Height (z).
        private func primitiveNode(_ def: ModelDef) -> SCNNode? {
            let (l, w, h) = (CGFloat(max(def.length, 0.001)), CGFloat(max(def.width, 0.001)), CGFloat(max(def.height, 0.001)))
            let node: SCNNode
            switch def.primitive.lowercased() {
            case "cylinder", "head", "conventional", "pigtail":
                node = SCNNode(geometry: SCNCylinder(radius: 0.5, height: 1))   // axis Y -> turned onto Z
                node.eulerAngles.x = .pi / 2
                node.scale = SCNVector3(l, h, w)
            case "sphere":
                node = SCNNode(geometry: SCNSphere(radius: 0.5))
                node.scale = SCNVector3(l, w, h)
            default:    // Cube, Base, Yoke, Scanner, Undefined, Plane ...
                node = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
                node.scale = SCNVector3(l, w, h)
            }
            let tone: CGFloat
            switch def.primitive.lowercased() {
            case "base": tone = 0.25
            case "yoke": tone = 0.35
            case "head", "scanner", "conventional": tone = 0.30
            default: tone = 0.5
            }
            node.geometry?.materials = [Self.material(NSColor(white: tone, alpha: 1))]
            return node
        }
    }
}
