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

    func testSubscribeHonorsTheConfiguredTimeoutAcrossMultiplePolls() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyHeadersURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var statusPolls = 0

        ProxyHeadersURLProtocol.requestHandler = { request in
            let target = try XCTUnwrap(request.value(forHTTPHeaderField: "x-fal-target-url"))
            let body: String
            if request.httpMethod == "POST" {
                body = #"{"request_id":"request-id"}"#
            } else if target.contains("/status") {
                statusPolls += 1
                body = statusPolls >= 5
                    ? #"{"status":"COMPLETED","logs":[],"response_url":"https://queue.fal.run/fal-ai/test-model/requests/request-id"}"#
                    : #"{"status":"IN_PROGRESS","logs":[]}"#
            } else {
                body = #"{"ok":true}"#
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        let client = FalClient(config: ClientConfig(
            requestProxy: "https://proxy.example/fal/proxy/index",
            session: session
        ))
        let result: Payload = try await client.subscribe(
            to: "fal-ai/test-model",
            pollInterval: .milliseconds(40),
            timeout: .milliseconds(250)
        )

        XCTAssertEqual(statusPolls, 5)
        XCTAssertEqual(result, ["ok": true])
    }
}
