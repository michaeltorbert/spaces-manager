import Foundation

// MARK: - Released version checks for local dev builds

struct ReleasedVersion {
    let displayVersion: String
    let downloadURL: URL?
    let infoURL: URL?
}

private enum ReleasedVersionCheckError: Error {
    case missingData
    case noReleaseInAppcast
}

enum ReleasedVersionChecker {
    static func fetchLatest(feedURL: URL,
                            completion: @escaping (Result<ReleasedVersion, Error>) -> Void) {
        URLSession.shared.dataTask(with: feedURL) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(ReleasedVersionCheckError.missingData))
                return
            }

            let parser = AppcastReleaseParser()
            do {
                let releases = try parser.parse(data: data)
                guard let latest = releases.max(by: {
                    compareVersions($0.displayVersion, $1.displayVersion) == .orderedAscending
                }) else {
                    completion(.failure(ReleasedVersionCheckError.noReleaseInAppcast))
                    return
                }
                completion(.success(latest))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }
}

private final class AppcastReleaseParser: NSObject, XMLParserDelegate {
    private struct PartialItem {
        var title: String?
        var displayVersion: String?
        var version: String?
        var downloadURL: URL?
        var infoURL: URL?
    }

    private var releases: [ReleasedVersion] = []
    private var currentItem: PartialItem?
    private var currentElement: String?
    private var textBuffer = ""

    func parse(data: Data) throws -> [ReleasedVersion] {
        releases = []
        currentItem = nil
        currentElement = nil
        textBuffer = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? ReleasedVersionCheckError.noReleaseInAppcast
        }
        return releases
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(qName ?? elementName)
        textBuffer = ""
        currentElement = name

        if name == "item" {
            currentItem = PartialItem()
            return
        }

        guard currentItem != nil else { return }
        if name == "enclosure" {
            if let value = attribute(attributeDict, named: ["url"]),
               let url = URL(string: value) {
                currentItem?.downloadURL = url
            }
            if let value = attribute(
                attributeDict,
                named: ["sparkle:shortVersionString", "shortVersionString"]
            ) {
                currentItem?.displayVersion = value
            }
            if let value = attribute(attributeDict, named: ["sparkle:version", "version"]) {
                currentItem?.version = value
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentItem != nil, currentElement != nil else { return }
        textBuffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(qName ?? elementName)
        guard currentItem != nil else {
            currentElement = nil
            textBuffer = ""
            return
        }

        if name == "item" {
            finishCurrentItem()
            return
        }

        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch name {
            case "title":
                currentItem?.title = text
            case "shortVersionString":
                currentItem?.displayVersion = text
            case "version":
                currentItem?.version = text
            case "link":
                currentItem?.infoURL = URL(string: text)
            default:
                break
            }
        }
        currentElement = nil
        textBuffer = ""
    }

    private func finishCurrentItem() {
        defer {
            currentItem = nil
            currentElement = nil
            textBuffer = ""
        }

        guard let item = currentItem else { return }
        let displayVersion = item.displayVersion ?? item.title ?? item.version
        guard let displayVersion, !displayVersion.isEmpty else { return }
        releases.append(ReleasedVersion(
            displayVersion: displayVersion,
            downloadURL: item.downloadURL,
            infoURL: item.infoURL
        ))
    }

    private func attribute(_ attributes: [String: String], named names: [String]) -> String? {
        for name in names {
            if let value = attributes[name] {
                return value
            }
        }
        for (key, value) in attributes where names.contains(localName(key)) {
            return value
        }
        return nil
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
