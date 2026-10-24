#!/usr/bin/env swift
// Public-key-only verification of Sparkle 2.10 archives and signed appcasts.
// The envelope follows common_cli/Signing.swift and SPUExtractSignedFeed.m.
import CryptoKit
import Foundation

private let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
private let officialDownloadPrefix = "https://github.com/ictechgy/river/releases/download/"
private let maximumFeedBytes = 1_048_576
private let maximumArchiveBytes: UInt64 = 2_147_483_648

struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationFailure(message: message) }
}

func canonicalBase64(_ value: String, count: Int) throws -> Data {
    guard let data = Data(base64Encoded: value), data.count == count,
          data.base64EncodedString() == value else {
        throw VerificationFailure(message: "Invalid canonical base64 key or signature")
    }
    return data
}

func boundedData(_ path: String, limit: UInt64) throws -> Data {
    let url = URL(fileURLWithPath: path)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    try require(attributes[.type] as? FileAttributeType == .typeRegular,
                "Input must be a regular file")
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
    try require(size > 0 && size <= limit, "Input file exceeds its size limit or is empty")
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try require(UInt64(data.count) == size && UInt64(data.count) <= limit,
                "Input file changed while reading")
    return data
}

func verifySignature(_ data: Data, signature: String, publicKey: String) throws {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: canonicalBase64(publicKey, count: 32))
    let signatureData = try canonicalBase64(signature, count: 64)
    try require(key.isValidSignature(signatureData, for: data), "Ed25519 signature verification failed")
}

struct FeedItem {
    let build: String
    let version: String
    let url: String
    let length: UInt64
    let signature: String
}

func signedFeedContent(_ data: Data, publicKey: String) throws -> Data {
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    // Sparkle searches backwards for this exact marker. Require one terminal
    // envelope so the audit tool also rejects ambiguous/trailing unsigned data.
    guard let marker = data.range(of: prefix, options: .backwards) else {
        throw VerificationFailure(message: "Missing Sparkle feed signature")
    }
    let content = data.subdata(in: 0..<marker.lowerBound)
    try require(content.range(of: prefix) == nil, "Duplicate Sparkle feed signatures")
    guard let block = String(data: data.subdata(in: marker.upperBound..<data.count), encoding: .utf8) else {
        throw VerificationFailure(message: "Feed signature block must be UTF-8")
    }
    let lines = block.components(separatedBy: "\n")
    try require(lines.count == 4 && lines[2] == "-->" && lines[3].isEmpty,
                "Malformed or non-terminal Sparkle signature block")
    try require(lines[0].hasPrefix("edSignature: ") && lines[1].hasPrefix("length: "),
                "Malformed Sparkle signature fields")
    let signature = String(lines[0].dropFirst("edSignature: ".count))
    let length = String(lines[1].dropFirst("length: ".count))
    try require(length == String(content.count), "Signed feed content length differs")
    try verifySignature(content, signature: signature, publicKey: publicKey)
    return content
}

func child(_ element: XMLElement, name: String) throws -> XMLElement {
    let matches = element.elements(forName: name)
    try require(matches.count == 1, "Missing or duplicate appcast element: \(name)")
    let expectedNamespace = name.hasPrefix("sparkle:") ? sparkleNamespace : nil
    try require(matches[0].uri == expectedNamespace, "Unexpected element namespace: \(name)")
    return matches[0]
}

func feedItem(_ content: Data) throws -> FeedItem {
    guard let text = String(data: content, encoding: .utf8) else {
        throw VerificationFailure(message: "Feed must be UTF-8")
    }
    try require(!text.contains("\0") && !text.uppercased().contains("<!DOCTYPE") &&
                !text.uppercased().contains("<!ENTITY"), "DTD and entities are forbidden")
    let document = try XMLDocument(data: content, options: [.nodeLoadExternalEntitiesNever])
    guard let root = document.rootElement() else {
        throw VerificationFailure(message: "Missing RSS root")
    }
    try require(document.dtd == nil && root.name == "rss" && root.attribute(forName: "version")?.stringValue == "2.0",
                "Expected an RSS 2.0 appcast")
    try require(root.namespace(forPrefix: "sparkle")?.stringValue == sparkleNamespace,
                "Unexpected Sparkle XML namespace")
    let channel = try child(root, name: "channel")
    let item = try child(channel, name: "item")
    // River deliberately publishes one current full update, with embedded plain
    // text notes. No external notes, deltas, scripts, channels or alternate URLs.
    let allowed = Set(["title", "pubDate", "description", "sparkle:version", "sparkle:shortVersionString",
                       "sparkle:minimumSystemVersion", "sparkle:hardwareRequirements", "enclosure"])
    for node in item.children ?? [] where node.kind == .element {
        try require(allowed.contains(node.name ?? ""), "Unexpected appcast item element")
    }
    let build = try child(item, name: "sparkle:version").stringValue ?? ""
    try require(build.range(of: #"^[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil &&
                (UInt64(build) ?? UInt64.max) <= 2_147_483_647, "Build number must be a bounded positive integer")
    let version = try child(item, name: "sparkle:shortVersionString").stringValue ?? ""
    try require(version.utf8.count <= 128 && version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil,
                "Display version must be SemVer")
    let withoutMetadata = version.split(separator: "+", maxSplits: 1)[0]
    if let separator = withoutMetadata.firstIndex(of: "-") {
        let prerelease = withoutMetadata[withoutMetadata.index(after: separator)...]
        for component in prerelease.split(separator: ".") {
            try require(!(component.allSatisfy(\.isNumber) && component.count > 1 && component.first == "0"),
                        "SemVer numeric prerelease components cannot have leading zeroes")
        }
    }
    try require(try child(item, name: "sparkle:minimumSystemVersion").stringValue == "14.0",
                "Unexpected minimum macOS version")
    try require(try child(item, name: "sparkle:hardwareRequirements").stringValue == "arm64",
                "Unexpected update architecture")
    let notes = try child(item, name: "description")
    try require(notes.attribute(forName: "sparkle:format")?.stringValue == "plain-text" &&
                !(notes.children ?? []).contains(where: { $0.kind == .element }) &&
                (notes.stringValue ?? "").utf8.count <= 32_768,
                "Release notes must be bounded embedded plain text")
    let enclosure = try child(item, name: "enclosure")
    let permittedAttributes = Set(["url", "length", "type", "sparkle:os", "sparkle:edSignature"])
    try require(Set((enclosure.attributes ?? []).compactMap(\.name)) == permittedAttributes,
                "Unexpected enclosure attributes")
    try require(!(enclosure.children ?? []).contains(where: { $0.kind == .element }),
                "Enclosure cannot contain nested elements")
    let expectedURL = officialDownloadPrefix + "v\(version)/River-\(version)-macos-arm64.dmg"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL &&
                enclosure.attribute(forName: "type")?.stringValue == "application/octet-stream" &&
                enclosure.attribute(forName: "sparkle:os")?.stringValue == "macos",
                "Unexpected update download URL, type or operating system")
    let lengthString = enclosure.attribute(forName: "length")?.stringValue ?? ""
    guard let length = UInt64(lengthString), length > 0, length <= maximumArchiveBytes,
          String(length) == lengthString else {
        throw VerificationFailure(message: "Invalid update archive length")
    }
    let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue ?? ""
    _ = try canonicalBase64(signature, count: 64)
    return FeedItem(build: build, version: version, url: expectedURL, length: length, signature: signature)
}

func selfTest() throws {
    let key = Curve25519.Signing.PrivateKey() // Ephemeral; never persisted or exported.
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let archive = Data("ephemeral archive fixture".utf8)
    let signature = try key.signature(for: archive).base64EncodedString()
    try verifySignature(archive, signature: signature, publicKey: publicKey)
    var rejected = 0
    func reject(_ work: () throws -> Void) throws {
        do { try work() } catch { rejected += 1; return }
        throw VerificationFailure(message: "Self-test accepted an invalid input")
    }
    try reject { try verifySignature(Data("tampered".utf8), signature: signature, publicKey: publicKey) }
    try reject { try verifySignature(archive, signature: signature, publicKey: otherKey) }
    try reject { try verifySignature(archive, signature: "bad", publicKey: publicKey) }
    let content = Data("<?xml version=\"1.0\"?><rss version=\"2.0\"/>\n".utf8)
    let feedSignature = try key.signature(for: content).base64EncodedString()
    let envelope = Data("<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(content.count)\n-->\n".utf8)
    var signed = content
    signed.append(envelope)
    try require(try signedFeedContent(signed, publicKey: publicKey) == content, "Feed round trip failed")
    try reject { _ = try signedFeedContent(signed, publicKey: otherKey) }
    try reject { _ = try signedFeedContent(content, publicKey: publicKey) }
    var tampered = signed
    tampered[0] ^= 1
    try reject { _ = try signedFeedContent(tampered, publicKey: publicKey) }
    var trailing = signed
    trailing.append(Data("unsigned".utf8))
    try reject { _ = try signedFeedContent(trailing, publicKey: publicKey) }
    var duplicate = signed
    duplicate.append(envelope)
    try reject { _ = try signedFeedContent(duplicate, publicKey: publicKey) }
    let badLength = Data(String(decoding: signed, as: UTF8.self).replacingOccurrences(of: "length: \(content.count)", with: "length: 1").utf8)
    try reject { _ = try signedFeedContent(badLength, publicKey: publicKey) }
    try reject { _ = try feedItem(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss/>".utf8)) }
    try reject { _ = try feedItem(Data("<rss>".utf8)) }
    let completeXML = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:sparkle="\(sparkleNamespace)"><channel><item>
    <title>River 0.1.0-alpha.6</title><pubDate>Sat, 24 Oct 2026 00:00:00 GMT</pubDate>
    <sparkle:version>7</sparkle:version><sparkle:shortVersionString>0.1.0-alpha.6</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
    <description sparkle:format="plain-text">Owned ephemeral test fixture.</description>
    <enclosure url="\(officialDownloadPrefix)v0.1.0-alpha.6/River-0.1.0-alpha.6-macos-arm64.dmg" length="\(archive.count)" type="application/octet-stream" sparkle:os="macos" sparkle:edSignature="\(signature)"/>
    </item></channel></rss>
    """
    let completeData = Data(completeXML.utf8)
    let completeItem = try feedItem(completeData)
    try require(completeItem.build == "7" && completeItem.length == UInt64(archive.count), "Complete appcast parse failed")
    let completeSignature = try key.signature(for: completeData).base64EncodedString()
    var completeSigned = completeData
    completeSigned.append(Data("<!-- sparkle-signatures:\nedSignature: \(completeSignature)\nlength: \(completeData.count)\n-->\n".utf8))
    _ = try feedItem(signedFeedContent(completeSigned, publicKey: publicKey))
    for (old, replacement) in [
        ("https://github.com/ictechgy/river/", "https://attacker.invalid/"),
        ("0.1.0-alpha.6", "0.1.0-alpha.06"),
        ("<sparkle:version>7</sparkle:version>", "<sparkle:version>0</sparkle:version>"),
        ("<sparkle:hardwareRequirements>arm64", "<sparkle:hardwareRequirements>x86_64"),
        ("sparkle:format=\"plain-text\"", "sparkle:format=\"html\""),
        ("<enclosure url=", "<enclosure sparkle:version=\"100\" url="),
        ("<sparkle:version>7", "<sparkle:version xmlns:sparkle=\"https://attacker.invalid\">7")
    ] {
        try reject { _ = try feedItem(Data(completeXML.replacingOccurrences(of: old, with: replacement).utf8)) }
    }
    print("Public-key verification self-test passed: 3 round trips, \(rejected) rejected invalid inputs")
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] { try selfTest(); return }
    if arguments == ["--help"] || arguments.isEmpty {
        print("Usage: swift scripts/verify_update.swift --public-key BASE64 [--feed appcast.xml] [--archive update.dmg] [--signature BASE64]")
        print("With --feed and --archive, verify both signatures and exact enclosure length/name. No Keychain access is used.")
        return
    }
    let allowed = Set(["--public-key", "--feed", "--archive", "--signature"])
    var options: [String: String] = [:]
    try require(arguments.count.isMultiple(of: 2), "Each option requires a value")
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let name = arguments[index]
        try require(allowed.contains(name) && options[name] == nil, "Unknown or duplicate option")
        options[name] = arguments[index + 1]
    }
    guard let publicKey = options["--public-key"] else {
        throw VerificationFailure(message: "--public-key is required")
    }
    _ = try canonicalBase64(publicKey, count: 32)
    try require(options["--feed"] != nil || options["--archive"] != nil, "Supply --feed or --archive")
    var result: [String: Any] = [:]
    var item: FeedItem?
    if let path = options["--feed"] {
        try require(options["--signature"] == nil, "Feed signatures are embedded; omit --signature")
        let data = try boundedData(path, limit: UInt64(maximumFeedBytes))
        item = try feedItem(signedFeedContent(data, publicKey: publicKey))
        result["feed_verified"] = true
        result["build_number"] = item?.build
        result["version"] = item?.version
        result["url"] = item?.url
    }
    if let path = options["--archive"] {
        let data = try boundedData(path, limit: maximumArchiveBytes)
        if let item {
            try require(UInt64(data.count) == item.length, "Archive length differs from signed enclosure")
            try require(URL(fileURLWithPath: path).lastPathComponent == URL(string: item.url)?.lastPathComponent,
                        "Archive filename differs from signed enclosure")
        }
        guard let signature = item?.signature ?? options["--signature"] else {
            throw VerificationFailure(message: "Archive verification requires --feed or --signature")
        }
        try verifySignature(data, signature: signature, publicKey: publicKey)
        result["archive_verified"] = true
        result["archive_sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        result["archive_length"] = data.count
    }
    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}

do { try main() } catch {
    FileHandle.standardError.write(Data("Update verification failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
