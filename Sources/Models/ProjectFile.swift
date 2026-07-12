import CoreMedia
import Foundation

/// 편집 내용(세그먼트, crop)을 JSON으로 저장/복원하기 위한 모델.
/// 시간은 초(Double)가 아니라 value/timescale 그대로 저장해 정밀도를 유지한다.
struct ProjectFile: Codable {
    struct TimeValue: Codable {
        var value: Int64
        var timescale: Int32

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
        }

        var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    }

    struct SegmentData: Codable {
        var start: TimeValue
        var duration: TimeValue
    }

    struct RectData: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var version: Int = 1
    var sourcePath: String
    var segments: [SegmentData]
    var cropAspect: String
    var cropRect: RectData

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    static func read(from url: URL) throws -> ProjectFile {
        try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
    }
}
