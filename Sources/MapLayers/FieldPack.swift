import Foundation
import MapKit
import MapMatchCore

/// The set of georeferenced maps exported by the Mac app for the iPhone app: a folder holding
/// `maps.json` and, per map, a tile pack (or, from older exports, one image) warped onto Web Mercator.
public struct FieldPack: Codable, Equatable, Sendable {
    public static let manifestName = "maps.json"

    public var exported: Date
    /// In layer order: first = top layer.
    public var maps: [FieldMap]
    /// Phone edits the Mac has merged; the phone drops them from its list of pending changes.
    public var appliedEdits: [UUID]?

    public init(exported: Date, maps: [FieldMap], appliedEdits: [UUID]? = nil) {
        self.exported = exported
        self.maps = maps
        self.appliedEdits = appliedEdits
    }

    public static func decode(_ data: Data) throws -> FieldPack {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(FieldPack.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

public struct FieldMap: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    /// Single warped image within the pack folder (older exports).
    public var file: String?
    /// Tile pack within the pack folder, with its zoom range (current exports).
    public var tiles: String?
    public var minZoom: Int?
    public var maxZoom: Int?
    /// Changes when the map's points, model or image change; lets export and sync skip unchanged maps.
    public var fingerprint: String?
    /// Edges of the warped image in degrees. The image is a Web Mercator rectangle, so its
    /// corners pin it down exactly.
    public var north: Double, south: Double, west: Double, east: Double
    public var points: Int
    /// Leave-one-out RMS error in metres; nil with too few points to tell.
    public var errorMetres: Double?
    public var model: String
    /// Layer settings on the Mac at export time, used as the phone's starting point.
    public var visible: Bool
    public var opacity: Double
    /// The control points and model the tiles were made with, so the phone can turn a spot on the
    /// overlay back into old-map pixels when you add a point.
    public var controlPoints: [ControlPoint]?
    public var kind: TransformKind?
    public var smoothing: Smoothing?
    public var imageWidth: Double?
    public var imageHeight: Double?

    public var id: String { name }

    public init(name: String, file: String? = nil, tiles: String? = nil, minZoom: Int? = nil, maxZoom: Int? = nil,
                fingerprint: String? = nil, rect: MKMapRect, points: Int, errorMetres: Double?, model: String,
                visible: Bool, opacity: Double) {
        self.name = name; self.file = file; self.tiles = tiles; self.minZoom = minZoom; self.maxZoom = maxZoom
        self.fingerprint = fingerprint
        let nw = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let se = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        north = nw.latitude; west = nw.longitude; south = se.latitude; east = se.longitude
        self.points = points; self.errorMetres = errorMetres; self.model = model
        self.visible = visible; self.opacity = opacity
    }

    public var mapRect: MKMapRect {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        return MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }
}

/// A change to a map's control points made on the phone. The phone writes them to
/// `edits from iPhone.json` in the pack folder; the Mac merges them into its point files.
public struct PhoneEdit: Codable, Identifiable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case add, enable, disable, delete }

    public var id: UUID
    /// The map's name (its image file name without extension).
    public var map: String
    public var date: Date
    public var action: Action
    /// The new point, for `add`.
    public var point: ControlPoint?
    /// The point affected, for the other actions.
    public var pointID: UUID?

    public init(map: String, action: Action, point: ControlPoint? = nil, pointID: UUID? = nil) {
        id = UUID(); self.map = map; date = Date(); self.action = action; self.point = point; self.pointID = pointID
    }
}

public struct PhoneEdits: Codable, Equatable, Sendable {
    public static let fileName = "edits from iPhone.json"
    public var edits: [PhoneEdit]

    public init(edits: [PhoneEdit]) { self.edits = edits }

    public static func decode(_ data: Data) throws -> PhoneEdits {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(PhoneEdits.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Applies edits in order. Adds of points that already exist and changes to points that no longer
    /// exist are skipped, so applying the same edits twice, or after edits on the Mac, is harmless.
    public static func apply(_ edits: [PhoneEdit], to points: [ControlPoint]) -> [ControlPoint] {
        var out = points
        for e in edits {
            switch e.action {
            case .add:
                if let p = e.point, !out.contains(where: { $0.id == p.id }) { out.append(p) }
            case .enable, .disable:
                if let i = out.firstIndex(where: { $0.id == e.pointID }) { out[i].enabled = e.action == .enable }
            case .delete:
                out.removeAll { $0.id == e.pointID }
            }
        }
        return out
    }
}
