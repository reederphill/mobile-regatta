import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RegattaAdminClient

// regatta-admin (#154): the admin tool's command line. Each command is one request to a server's `/admin/` routes,
// as the admin whose token is in REGATTA_ADMIN_TOKEN (never an argument: it would show in the process list and the
// shell's history); the answer's JSON is printed. Exits 0 on a 2xx answer, 1 otherwise, 2 on a usage error.

let environment = ProcessInfo.processInfo.environment
let request: AdminRequest
do {
    request = try AdminCommand.request(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
guard let token = environment["REGATTA_ADMIN_TOKEN"], !token.isEmpty else {
    FileHandle.standardError.write(Data("REGATTA_ADMIN_TOKEN is unset: it is the admin's token\n".utf8))
    exit(2)
}
let base = environment["REGATTA_ADMIN_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8080"
guard let server = URL(string: base), let url = request.url(on: server) else {
    FileHandle.standardError.write(Data("REGATTA_ADMIN_URL=\(base) isn't a URL\n".utf8))
    exit(2)
}
var urlRequest = URLRequest(url: url)
urlRequest.httpMethod = request.method
urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var status = 1
URLSession.shared.dataTask(with: urlRequest) { data, response, error in
    defer { done.signal() }
    if let error {
        FileHandle.standardError.write(Data("can't reach \(base): \(error.localizedDescription)\n".utf8))
        return
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    var body = data ?? Data()
    if let object = try? JSONSerialization.jsonObject(with: body),
       let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        body = pretty
    }
    FileHandle.standardOutput.write(body + Data("\n".utf8))
    if !(200..<300).contains(code) { FileHandle.standardError.write(Data("HTTP \(code)\n".utf8)) }
    status = (200..<300).contains(code) ? 0 : 1
}.resume()
done.wait()
exit(Int32(status))
