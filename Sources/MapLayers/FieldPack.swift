import Foundation
import MapKit

/// The set of georeferenced maps exported by the Mac app for the iPhone app: a folder holding
/// `maps.json` and one image per map, already warped onto Web Mercator.
public struct FieldPack: Codable, Equatable, Sendable {
    public static let manifestName = "maps.json"

    public var exported: Date
    /// In layer order: first = top layer.
    public var maps: [FieldMap]

    public init(exported: Date, maps: [FieldMap]) {
        self.exported = exported
        self.maps = maps
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
    /// Image file name within the pack folder.
    public var file: String
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

    public var id: String { name }

    public init(name: String, file: String, rect: MKMapRect, points: Int, errorMetres: Double?, model: String,
                visible: Bool, opacity: Double) {
        self.name = name; self.file = file
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
