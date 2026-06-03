import Foundation
import Darwin

struct Endpoint {
    let name: String
    let url: URL
}

let endpoints: [Endpoint] = [
    Endpoint(
        name: "konachan.com post.json",
        url: URL(string: "https://konachan.com/post.json?limit=1&page=1&tags=rating%3As")!
    ),
    Endpoint(
        name: "konachan.com tag.json",
        url: URL(string: "https://konachan.com/tag.json?limit=3&name_pattern=sky*&order=count")!
    ),
    Endpoint(
        name: "konachan.com tag.json name=sky",
        url: URL(string: "https://konachan.com/tag.json?limit=5&name=sky")!
    ),
    Endpoint(
        name: "konachan.com tag.json name_pattern=sky",
        url: URL(string: "https://konachan.com/tag.json?limit=5&name_pattern=sky")!
    ),
    Endpoint(
        name: "konachan.com post.json order score",
        url: URL(string: "https://konachan.com/post.json?limit=1&page=1&tags=landscape%20rating%3As%20order%3Ascore")!
    ),
    Endpoint(
        name: "konachan.net post.json",
        url: URL(string: "https://konachan.net/post.json?limit=1&page=1&tags=rating%3As")!
    )
]

func resolvedIPv4Addresses(for host: String) -> [String] {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_INET,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0, let result else {
        return ["getaddrinfo failed: \(String(cString: gai_strerror(status)))"]
    }
    defer { freeaddrinfo(result) }

    var addresses: [String] = []
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let info = current {
        if let addr = info.pointee.ai_addr {
            var storage = sockaddr_in()
            memcpy(&storage, addr, MemoryLayout<sockaddr_in>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var rawAddress = storage.sin_addr
            inet_ntop(AF_INET, &rawAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
            addresses.append(String(cString: buffer))
        }
        current = info.pointee.ai_next
    }
    return addresses
}

func previewText(from data: Data, maxLength: Int = 600) -> String {
    let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    if text.count <= maxLength {
        return text
    }
    return String(text.prefix(maxLength)) + "...<truncated>"
}

func runRequest(_ endpoint: Endpoint) async {
    let host = endpoint.url.host ?? "<missing-host>"
    print("\n=== \(endpoint.name) ===")
    print("URL: \(endpoint.url.absoluteString)")
    print("Resolved IPv4: \(resolvedIPv4Addresses(for: host).joined(separator: ", "))")

    var request = URLRequest(url: endpoint.url)
    request.timeoutInterval = 20
    request.setValue("WaifuX/1.0 KonachanAPIProbe", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let startedAt = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startedAt)

        if let http = response as? HTTPURLResponse {
            print("HTTP: \(http.statusCode)")
            print("Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "<none>")")
            print("Bytes: \(data.count)")
            print(String(format: "Elapsed: %.2fs", elapsed))
        } else {
            print("Response: \(response)")
        }

        if endpoint.url.path.hasSuffix(".json") {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                print("JSON parsed: \(type(of: object))")
                print("Preview: \(previewText(from: data))")
            } catch {
                print("JSON parse failed: \(error)")
                print("Preview: \(previewText(from: data))")
            }
        } else {
            print("Preview: \(previewText(from: data))")
        }
    } catch {
        print("Request failed: \(error)")
    }
}

for endpoint in endpoints {
    await runRequest(endpoint)
}

print("\n=== konachan.net pagination probe ===")
for page in 1...8 {
    let url = URL(string: "https://konachan.net/post.json?limit=24&page=\(page)&tags=rating%3As")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("WaifuX/1.0 KonachanAPIProbe", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let posts = try JSONDecoder().decode([KonachanProbePost].self, from: data)
        print("page=\(page) http=\(status) count=\(posts.count) first=\(posts.first?.id ?? -1) last=\(posts.last?.id ?? -1)")
    } catch {
        print("page=\(page) failed: \(error)")
    }
}

struct KonachanProbePost: Decodable {
    let id: Int
}

struct KonachanProbeTag: Decodable {
    let id: Int
    let name: String
    let count: Int
    let type: Int?
}

func makeKonachanNetURL(path: String, items: [URLQueryItem]) -> URL {
    var components = URLComponents(string: "https://konachan.net")!
    components.path = path
    components.queryItems = items
    return components.url!
}

func fetchJSON<T: Decodable>(_ type: T.Type, url: URL) async throws -> (Int, T) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("WaifuX/1.0 KonachanAPIProbe", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, try JSONDecoder().decode(T.self, from: data))
}

let categoryQueries = [
    "genshin_impact",
    "honkai_star_rail",
    "zenless_zone_zero",
    "fate_grand_order",
    "touhou",
    "blue_archive",
    "azur_lane",
    "vocaloid",
    "landscape",
    "cyberpunk"
]

let hotTagQueries = [
    "1girl",
    "long_hair",
    "school_uniform",
    "swimsuit",
    "glasses",
    "smile"
]

print("\n=== konachan.net preset tag probe ===")
for query in categoryQueries + hotTagQueries {
    let postURL = makeKonachanNetURL(path: "/post.json", items: [
        URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "tags", value: "\(query) rating:s")
    ])
    let tagURL = makeKonachanNetURL(path: "/tag.json", items: [
        URLQueryItem(name: "limit", value: "5"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "name", value: query)
    ])

    do {
        let (postStatus, posts) = try await fetchJSON([KonachanProbePost].self, url: postURL)
        let (tagStatus, tags) = try await fetchJSON([KonachanProbeTag].self, url: tagURL)
        let tagSummary = tags.map { "\($0.name)(\($0.count))" }.joined(separator: ", ")
        print("query=\(query) posts_http=\(postStatus) posts=\(posts.count) tag_http=\(tagStatus) tags=[\(tagSummary)]")
    } catch {
        print("query=\(query) failed: \(error)")
    }
}

print("\n=== konachan.net sorting probe ===")
for order in ["score", "favcount", "landscape", "portrait", "random", "mpixels"] {
    let url = makeKonachanNetURL(path: "/post.json", items: [
        URLQueryItem(name: "limit", value: "3"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "tags", value: "rating:s order:\(order)")
    ])
    do {
        let (status, posts) = try await fetchJSON([KonachanProbePost].self, url: url)
        print("order:\(order) http=\(status) count=\(posts.count) ids=\(posts.map { String($0.id) }.joined(separator: ","))")
    } catch {
        print("order:\(order) failed: \(error)")
    }
}

print("\n=== konachan.net rating probe ===")
for rating in ["s", "q", "e"] {
    let url = makeKonachanNetURL(path: "/post.json", items: [
        URLQueryItem(name: "limit", value: "3"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "tags", value: "rating:\(rating)")
    ])
    do {
        let (status, posts) = try await fetchJSON([KonachanProbePost].self, url: url)
        print("rating:\(rating) http=\(status) count=\(posts.count) ids=\(posts.map { String($0.id) }.joined(separator: ","))")
    } catch {
        print("rating:\(rating) failed: \(error)")
    }
}
