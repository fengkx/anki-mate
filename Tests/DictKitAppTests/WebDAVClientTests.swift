import XCTest
@testable import DictKitApp

final class WebDAVClientTests: XCTestCase {
    func testUnauthorizedErrorUsesReadableMessageInsteadOfHTMLBody() {
        let html = """
        <!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
        <html><head><title>401 Unauthorized</title></head><body>
        <h1>Unauthorized</h1>
        <p>This server could not verify that you are authorized.</p>
        </body></html>
        """

        let error = WebDAVError.httpError(401, html)

        XCTAssertEqual(
            error.localizedDescription,
            "HTTP 401: Authentication was rejected. Check the server URL, username, and WebDAV/app password."
        )
    }

    func testOtherHTTPErrorStripsHTMLTags() {
        let error = WebDAVError.httpError(500, "<html><body><h1>Server Error</h1></body></html>")

        XCTAssertEqual(error.localizedDescription, "HTTP 500: Server Error")
    }
}
