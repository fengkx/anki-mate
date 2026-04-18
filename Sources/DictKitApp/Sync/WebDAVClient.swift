import Foundation

protocol WebDAVClientProtocol: Sendable {
    func get(_ path: String) async throws -> Data?
    func put(_ path: String, data: Data, contentType: String) async throws
    func delete(_ path: String) async throws
    func mkcol(_ path: String) async throws
    func exists(_ path: String) async throws -> Bool
    func ensureDirectoryStructure() async throws
    func listFiles(in path: String) async throws -> [String]
}

/// Lightweight WebDAV client using URLSession.
final class WebDAVClient: Sendable, WebDAVClientProtocol {
    let baseURL: URL
    private let session: URLSession
    private let authHeader: String

    init(credentials: WebDAVCredentials) throws {
        guard let url = credentials.baseURL else {
            throw WebDAVError.invalidURL
        }
        // Ensure base URL ends with /
        self.baseURL = url.absoluteString.hasSuffix("/") ? url : url.appendingPathComponent("")
        let credString = "\(credentials.username):\(credentials.password)"
        let credData = Data(credString.utf8)
        self.authHeader = "Basic \(credData.base64EncodedString())"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Core operations

    /// GET a resource. Returns nil if 404.
    func get(_ path: String) async throws -> Data? {
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await perform(request)
        if response.statusCode == 404 { return nil }
        try checkStatus(response, data: data, expected: 200)
        return data
    }

    /// PUT data to a path. Creates or overwrites.
    func put(_ path: String, data: Data, contentType: String = "application/octet-stream") async throws {
        var request = try makeRequest(path: path, method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await perform(request)
        // 201 Created or 204 No Content are both success
        guard (200...299).contains(response.statusCode) else {
            throw WebDAVError.httpError(response.statusCode, String(data: respData, encoding: .utf8) ?? "")
        }
    }

    /// DELETE a resource. Ignores 404.
    func delete(_ path: String) async throws {
        let request = try makeRequest(path: path, method: "DELETE")
        let (data, response) = try await perform(request)
        if response.statusCode == 404 { return }
        guard (200...299).contains(response.statusCode) else {
            throw WebDAVError.httpError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// MKCOL - create a directory. Ignores 405 (already exists).
    func mkcol(_ path: String) async throws {
        let request = try makeRequest(path: path, method: "MKCOL")
        let (data, response) = try await perform(request)
        // 201 Created, 405 Method Not Allowed (already exists)
        if response.statusCode == 405 { return }
        guard (200...299).contains(response.statusCode) else {
            throw WebDAVError.httpError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// HEAD - check if resource exists.
    func exists(_ path: String) async throws -> Bool {
        let request = try makeRequest(path: path, method: "HEAD")
        let (_, response) = try await perform(request)
        return response.statusCode == 200
    }

    /// Test the connection by doing a PROPFIND on the base path.
    func testConnection() async throws {
        var request = try makeRequest(path: "", method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (data, response) = try await perform(request)
        guard (200...299).contains(response.statusCode) || response.statusCode == 207 else {
            throw WebDAVError.httpError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Directory setup

    /// Ensure the remote directory structure exists.
    func ensureDirectoryStructure() async throws {
        try await mkcol("anki-mate/")
        try await mkcol("anki-mate/audio/")
        try await mkcol("anki-mate/backups/")
    }

    /// List file names in a directory using PROPFIND Depth:1.
    /// Returns relative file names (not directories) within the given path.
    func listFiles(in path: String) async throws -> [String] {
        var request = try makeRequest(path: path, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        let (data, response) = try await perform(request)
        guard response.statusCode == 207 || (200...299).contains(response.statusCode) else {
            if response.statusCode == 404 { return [] }
            throw WebDAVError.httpError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return parseFileNamesFromPropfind(data, basePath: path)
    }

    /// Parse PROPFIND 207 Multi-Status XML response to extract file names.
    /// Filters out directory entries (those ending with /) and the base path itself.
    private func parseFileNamesFromPropfind(_ data: Data, basePath: String) -> [String] {
        // Parse href values from the XML response
        // WebDAV PROPFIND returns XML with <d:href> or <D:href> elements
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }

        var fileNames: [String] = []
        // Simple regex-based extraction of href values
        // Handles both <d:href>, <D:href>, and <href> variants
        let pattern = "<[dD]?:?href>([^<]+)</[dD]?:?href>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: xmlString) else { continue }
            let href = String(xmlString[range])
                .removingPercentEncoding ?? String(xmlString[range])

            // Skip directories (ending with /) and the base path itself
            guard !href.hasSuffix("/") else { continue }

            // Extract just the file name from the full path
            if let lastComponent = href.split(separator: "/").last {
                fileNames.append(String(lastComponent))
            }
        }

        return fileNames
    }

    // MARK: - Helpers

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.networkError(URLError(.badServerResponse))
            }
            return (data, httpResponse)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    private func checkStatus(_ response: HTTPURLResponse, data: Data, expected: Int) throws {
        guard response.statusCode == expected else {
            throw WebDAVError.httpError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
