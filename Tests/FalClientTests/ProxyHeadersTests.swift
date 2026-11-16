@testable import FalClient
import Foundation
import XCTest

private final class ProxyHeadersURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ProxyHeadersTests: XCTestCase {
    override func tearDown() {
        ProxyHeadersURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAppliesDynamicHeadersOnlyToTheProxyRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyHeadersURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let expectation = expectation(description: "proxy request")

        ProxyHeadersURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://proxy.example/fal/proxy/index")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "short-lived-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-fal-target-url"), "https://fal.run/fal-ai/test-model")
            expectation.fulfill()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("{\"ok\":true}".utf8)
            )
        }

        let client = FalClient(config: ClientConfig(
            requestProxy: "https://proxy.example/fal/proxy/index",
            proxyHeadersProvider: { ["X-Firebase-AppCheck": "short-lived-token"] },
            session: session
        ))
        _ = try await client.run("fal-ai/test-model")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testRejectsAProviderThatOverridesProxyContractHeaders() async throws {
        let client = FalClient(config: ClientConfig(
            requestProxy: "https://proxy.example/fal/proxy/index",
            proxyHeadersProvider: { ["Authorization": "must-not-override"] }
        ))

        do {
            _ = try await client.run("fal-ai/test-model")
            XCTFail("Expected invalid proxy header")
        } catch FalError.invalidProxyHeader(let name) {
            XCTAssertEqual(name, "Authorization")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
