import Foundation
import AVFoundation
import ShazamKit

struct Song: Decodable {
    let file: String
    let title: String
    let artist: String
}

@main
struct Builder {
    static func main() async {
        do { try await run() }
        catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Lyriko", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: swift generate_catalog.swift songs.json output.shazamcatalog"])
        }
        let manifest = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let songs = try JSONDecoder().decode([Song].self, from: Data(contentsOf: manifest))
        let catalog = SHCustomCatalog()
        for song in songs {
            let file = manifest.deletingLastPathComponent().appendingPathComponent(song.file)
            print("Signing: \(song.artist) — \(song.title)")
            let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: file))
            let item = SHMediaItem(properties: [.title: song.title, .artist: song.artist])
            try catalog.addReferenceSignature(signature, representing: [item])
        }
        try catalog.dataRepresentation.write(to: output, options: .atomic)
        print("Built \(songs.count) references; \(catalog.dataRepresentation.count) bytes")
    }
}
