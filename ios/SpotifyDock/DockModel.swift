import Foundation
import Network
import Darwin

/// Поиск Mac: последний адрес → Bonjour (_spotifydock._tcp) → сканирование подсети → ручной ввод.
@MainActor
final class DockModel: NSObject, ObservableObject {
    @Published var webURL: URL?
    @Published var status = ""

    private let serviceType = "_spotifydock._tcp"
    private var browser: NWBrowser?
    private var resolver: NetService?
    private var resolving = false
    private var scanGen = 0
    private var started = false

    private static let probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.2
        c.timeoutIntervalForResource = 2.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: lifecycle
    func resume() {
        if webURL != nil { return }
        if !started {
            started = true
            if let s = UserDefaults.standard.string(forKey: "url"), let u = URL(string: s) {
                status = "Подключаюсь к последнему Mac…"
                Task {
                    if await probe(u) { open(u) } else { status = "Ищу Mac в сети…"; startDiscovery() }
                }
                return
            }
            status = "Ищу Mac в сети…\nЗапустите Spotify Dock на Mac"
        }
        startDiscovery()
    }

    func pause() { stopDiscovery() }

    func lost() {
        guard webURL != nil else { return }
        webURL = nil
        status = "Mac недоступен, ищу заново…"
        startDiscovery()
    }

    func rediscover() {
        UserDefaults.standard.removeObject(forKey: "url")
        webURL = nil
        status = "Ищу Mac в сети…"
        startDiscovery()
    }

    // MARK: connect
    private func open(_ url: URL) {
        stopDiscovery()
        UserDefaults.standard.set(url.absoluteString, forKey: "url")
        webURL = url
    }

    func connectManual(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") { t.removeFirst(7) }
        while t.hasSuffix("/") { t.removeLast() }
        if t.isEmpty { return }
        if !t.contains(":") || (t.hasPrefix("[") && t.hasSuffix("]")) { t += ":8765" }
        guard let url = URL(string: "http://\(t)/") else { status = "Неверный адрес"; return }
        status = "Проверяю \(t)…"
        Task {
            if await probe(url) { open(url) }
            else { status = "Не отвечает: \(t)\nПроверьте адрес в меню Spotify Dock на Mac" }
        }
    }

    private func probe(_ base: URL) async -> Bool {
        guard let u = URL(string: "api/state", relativeTo: base) else { return false }
        do {
            let (_, r) = try await Self.probeSession.data(from: u)
            return (r as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: Bonjour
    private func startDiscovery() {
        guard browser == nil, webURL == nil else { return }
        resolving = false
        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] st in
            if case .failed = st {
                Task { @MainActor in
                    self?.browser = nil
                    self?.status = "Поиск не запустился. Введите адрес вручную."
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                if case let .service(name, type, domain, _) = r.endpoint {
                    Task { @MainActor in self?.resolve(name: name, type: type, domain: domain) }
                    break
                }
            }
        }
        browser = b
        b.start(queue: .main)

        scanGen += 1
        let gen = scanGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.scanGen, self.webURL == nil else { return }
            self.scanSubnet(gen)
        }
    }

    private func stopDiscovery() {
        scanGen += 1
        browser?.cancel(); browser = nil
        resolver?.stop(); resolver = nil
        resolving = false
    }

    private func resolve(name: String, type: String, domain: String) {
        guard !resolving, webURL == nil else { return }
        resolving = true
        status = "Нашёл «\(name)», подключаюсь…"
        let s = NetService(domain: domain, type: type, name: name)
        s.delegate = self
        resolver = s
        s.resolve(withTimeout: 5)
    }

    // MARK: subnet scan
    private func scanSubnet(_ gen: Int) {
        guard let me = Self.localIPv4() else { return }
        let prefix = me.split(separator: ".").dropLast().joined(separator: ".")
        status = "Bonjour молчит, сканирую \(prefix).x…"
        Task {
            let found: URL? = await withTaskGroup(of: URL?.self) { group in
                var it = 0
                let targets: [(String, Int)] = (8765...8770).flatMap { p in (1...254).map { ("\(prefix).\($0)", p) } }.filter { $0.0 != me }
                var result: URL?
                func add() {
                    guard it < targets.count else { return }
                    let (h, p) = targets[it]; it += 1
                    group.addTask { await Self.check(host: h, port: p) }
                }
                for _ in 0..<48 { add() }
                while let r = await group.next() {
                    if let r { result = r; group.cancelAll(); break }
                    if gen != self.scanGen { group.cancelAll(); break }
                    add()
                }
                return result
            }
            guard gen == scanGen, webURL == nil else { return }
            if let found { open(found) }
            else {
                status = "Mac не найден в \(prefix).x\nПроверьте, что Spotify Dock запущен, или введите адрес"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if gen == scanGen, webURL == nil { scanSubnet(gen) }
            }
        }
    }

    nonisolated private static func check(host: String, port: Int) async -> URL? {
        guard let u = URL(string: "http://\(host):\(port)/api/state") else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 0.6
        guard let (data, resp) = try? await probeSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              String(decoding: data, as: UTF8.self).contains("\"hasTrack\"") else { return nil }
        return URL(string: "http://\(host):\(port)/")
    }

    nonisolated private static func localIPv4() -> String? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return nil }
        defer { freeifaddrs(ifa) }
        var best: (rank: Int, ip: String)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: i.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil else { continue }
            let rank = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            if best == nil || rank < best!.rank { best = (rank, ip) }
        }
        return best?.ip
    }
}

// MARK: NetService
extension DockModel: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        var ip: String?
        for d in sender.addresses ?? [] {
            d.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == UInt8(AF_INET) else { return }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(d.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0, ip == nil {
                    ip = String(cString: host)
                }
            }
        }
        let port = sender.port, name = sender.name
        Task { @MainActor in
            guard let ip, let url = URL(string: "http://\(ip):\(port)/") else { self.resolving = false; return }
            if await self.probe(url) { self.open(url) }
            else { self.resolving = false; self.status = "«\(name)» найден, но не отвечает (\(ip):\(port))" }
        }
    }
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.resolving = false
        }
    }
}
