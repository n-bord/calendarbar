import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injecting the HTTP boundary lets tests exercise real request construction without an account or URLSession daemon.
typealias HTTPRequestExecutor = (URLRequest) async throws -> (Data, URLResponse)

final class NoCredentialRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
