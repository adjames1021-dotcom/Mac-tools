import Foundation

/// One server from a subscription or share link, stored as a ready-made sing-box outbound.
struct ProxyServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var type: String
    var address: String
    var outbound: String  // sing-box outbound JSON (without "tag")
}

/// Turns Hiddify-style share links, base64 subscriptions and sing-box JSON into servers,
/// and builds the sing-box config that runs them.
enum ProxyLinks {
    static let proxyTypes: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria",
                                          "tuic", "wireguard", "socks", "http", "shadowtls", "ssh", "anytls"]

    /// Parses pasted text or a subscription body. Returns the servers and how many lines were skipped.
    static func parse(_ text: String) -> (servers: [ProxyServer], skipped: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return (parseSingBox(trimmed), 0) }
        if !trimmed.contains("://"), let decoded = base64(trimmed), decoded.contains("://") {
            return parse(decoded)
        }
        var servers: [ProxyServer] = []
        var skipped = 0
        for line in trimmed.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), !l.hasPrefix("//") else { continue }
            if let s = link(l) { servers.append(s) } else { skipped += 1 }
        }
        return (servers, skipped)
    }

    /// Takes the proxy outbounds out of a sing-box config (or a bare outbound list).
    static func parseSingBox(_ json: String) -> [ProxyServer] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [] }
        let list = (obj as? [String: Any])?["outbounds"] as? [[String: Any]] ?? (obj as? [[String: Any]]) ?? []
        return list.compactMap { o in
            guard let type = o["type"] as? String, proxyTypes.contains(type) else { return nil }
            var o = o
            let name = o.removeValue(forKey: "tag") as? String ?? type
            return server(name: name, o)
        }
    }

    static func link(_ link: String) -> ProxyServer? {
        guard let colon = link.range(of: "://") else { return nil }
        switch link[..<colon.lowerBound].lowercased() {
        case "vmess": return vmess(link)
        case "ss": return shadowsocks(link)
        case "vless", "trojan", "hysteria2", "hy2", "tuic": return standard(link)
        default: return nil
        }
    }

    // MARK: Link formats

    /// vless://, trojan://, hysteria2://, hy2://, tuic:// all share the user@host:port?query#name layout.
    private static func standard(_ link: String) -> ProxyServer? {
        guard let c = URLComponents(string: link), let host = c.host, let port = c.port,
              let user = c.percentEncodedUser?.removingPercentEncoding else { return nil }
        let q = query(c)
        let scheme = c.scheme!.lowercased()
        var o: [String: Any] = ["server": host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), "server_port": port]
        switch scheme {
        case "vless":
            o["type"] = "vless"
            o["uuid"] = user
            if let flow = q["flow"], !flow.isEmpty { o["flow"] = flow }
            if let tls = tls(q, defaultOn: false) { o["tls"] = tls }
            guard addTransport(&o, q) else { return nil }
        case "trojan":
            o["type"] = "trojan"
            o["password"] = user
            if let tls = tls(q, defaultOn: true) { o["tls"] = tls }
            guard addTransport(&o, q) else { return nil }
        case "hysteria2", "hy2":
            o["type"] = "hysteria2"
            // Password may itself contain ":" (user:pass auth), which URLComponents splits off.
            o["password"] = c.percentEncodedPassword.flatMap { user + ":" + ($0.removingPercentEncoding ?? $0) } ?? user
            o["tls"] = tls(q, defaultOn: true)
            if let obfs = q["obfs"], !obfs.isEmpty, obfs != "none" {
                o["obfs"] = ["type": obfs, "password": q["obfs-password"] ?? ""]
            }
        case "tuic":
            o["type"] = "tuic"
            o["uuid"] = user
            o["password"] = c.percentEncodedPassword?.removingPercentEncoding ?? ""
            if let cc = q["congestion_control"] { o["congestion_control"] = cc }
            if let mode = q["udp_relay_mode"] { o["udp_relay_mode"] = mode }
            o["tls"] = tls(q, defaultOn: true)
        default: return nil
        }
        return server(name: c.fragment ?? host, o)
    }

    /// vmess://BASE64({"add":…,"port":…,"id":…,"net":…,…}) — the v2rayN format.
    private static func vmess(_ link: String) -> ProxyServer? {
        guard let body = base64(String(link.dropFirst("vmess://".count))),
              let j = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        func s(_ k: String) -> String { (j[k].map { "\($0)" } ?? "").trimmingCharacters(in: .whitespaces) }
        guard !s("add").isEmpty, let port = Int(s("port")), !s("id").isEmpty else { return nil }
        var o: [String: Any] = ["type": "vmess", "server": s("add"), "server_port": port, "uuid": s("id"),
                                "security": s("scy").isEmpty ? "auto" : s("scy"), "alter_id": Int(s("aid")) ?? 0]
        let net = s("net")
        var q = ["type": net, "host": s("host"), "path": s("path"), "headerType": s("type"),
                 "security": s("tls"), "sni": s("sni"), "alpn": s("alpn"), "fp": s("fp")]
        if net == "grpc" { q["serviceName"] = s("path") }
        if let tls = tls(q.filter { !$0.value.isEmpty }, defaultOn: false) { o["tls"] = tls }
        guard addTransport(&o, q.filter { !$0.value.isEmpty }) else { return nil }
        return server(name: s("ps").isEmpty ? s("add") : s("ps"), o)
    }

    /// ss://BASE64(method:pass)@host:port, ss://method:pass@host:port, or legacy ss://BASE64(method:pass@host:port).
    private static func shadowsocks(_ link: String) -> ProxyServer? {
        var rest = String(link.dropFirst("ss://".count))
        var name: String?
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }
        var queryPart = ""
        if let qm = rest.firstIndex(of: "?") {
            queryPart = String(rest[qm...])
            rest = String(rest[..<qm])
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rest.contains("@") {
            guard let decoded = base64(rest) else { return nil }
            rest = decoded
        }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let encodedUser = String(rest[..<at])
        let userinfo = base64(encodedUser).flatMap { $0.contains(":") ? $0 : nil }
            ?? encodedUser.removingPercentEncoding ?? encodedUser
        guard let sep = userinfo.firstIndex(of: ":"),
              let c = URLComponents(string: "ss://x@" + rest[rest.index(after: at)...] + queryPart),
              let host = c.host, let port = c.port else { return nil }
        var o: [String: Any] = ["type": "shadowsocks", "server": host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                                "server_port": port, "method": String(userinfo[..<sep]),
                                "password": String(userinfo[userinfo.index(after: sep)...])]
        if let plugin = query(c)["plugin"], !plugin.isEmpty {  // SIP002: plugin=obfs-local;obfs=http;obfs-host=…
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            o["plugin"] = parts[0]
            if parts.count > 1 { o["plugin_opts"] = parts[1] }
        }
        return server(name: name ?? host, o)
    }

    // MARK: Shared pieces

    private static func tls(_ q: [String: String], defaultOn: Bool) -> [String: Any]? {
        let security = q["security"] ?? (defaultOn ? "tls" : "none")
        guard security == "tls" || security == "reality" || security == "xtls" else { return nil }
        var t: [String: Any] = ["enabled": true]
        if let sni = q["sni"] ?? q["peer"] ?? q["host"], !sni.isEmpty { t["server_name"] = sni }
        if ["1", "true"].contains(q["allowInsecure"] ?? q["insecure"] ?? q["allow_insecure"] ?? "") { t["insecure"] = true }
        if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map(String.init) }
        let fp = q["fp"] ?? (security == "reality" ? "chrome" : nil)  // REALITY needs uTLS
        if let fp = fp, !fp.isEmpty { t["utls"] = ["enabled": true, "fingerprint": fp] }
        if security == "reality" {
            t["reality"] = ["enabled": true, "public_key": q["pbk"] ?? "", "short_id": q["sid"] ?? ""]
        }
        return t
    }

    /// Adds the V2Ray transport. Returns false for transports sing-box can't run (e.g. xhttp).
    private static func addTransport(_ o: inout [String: Any], _ q: [String: String]) -> Bool {
        let host = q["host"] ?? ""
        var path = q["path"] ?? ""
        switch q["type"] ?? "tcp" {
        case "tcp", "raw", "":
            if q["headerType"] == "http" {
                o["transport"] = ["type": "http", "host": host.isEmpty ? [] : [host], "path": path.isEmpty ? "/" : path]
            }
        case "ws":
            var t: [String: Any] = ["type": "ws", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { t["headers"] = ["Host": host] }
            // Early data hint in the path (e.g. "/ws?ed=2048"), as Xray clients write it.
            if let r = path.range(of: #"[?&]ed=(\d+)"#, options: .regularExpression) {
                t["max_early_data"] = Int(path[r].drop { !$0.isNumber }) ?? 0
                t["early_data_header_name"] = "Sec-WebSocket-Protocol"
                path.removeSubrange(r)
                t["path"] = path.isEmpty ? "/" : path
            }
            o["transport"] = t
        case "grpc":
            o["transport"] = ["type": "grpc", "service_name": q["serviceName"] ?? q["service_name"] ?? ""]
        case "http", "h2":
            o["transport"] = ["type": "http", "host": host.isEmpty ? [] : [host], "path": path.isEmpty ? "/" : path]
        case "httpupgrade":
            o["transport"] = ["type": "httpupgrade", "host": host, "path": path.isEmpty ? "/" : path]
        case "quic":
            o["transport"] = ["type": "quic"]
        default:
            return false
        }
        return true
    }

    private static func query(_ c: URLComponents) -> [String: String] {
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return q
    }

    private static func server(name: String, _ o: [String: Any]) -> ProxyServer? {
        guard let type = o["type"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return nil }
        let port = o["server_port"].map { ":\($0)" } ?? ""
        return ProxyServer(name: name, type: type, address: "\(o["server"] ?? "")\(port)",
                           outbound: String(decoding: data, as: UTF8.self))
    }

    /// Decodes standard or URL-safe base64, with or without padding.
    static func base64(_ s: String) -> String? {
        var b = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        guard let data = Data(base64Encoded: b), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: sing-box config

    /// A config with each server as outbound "s0", "s1", … and a selector "proxy" that routes everything.
    /// `mixedPort` nil builds a config with no inbound (used for latency tests).
    static func config(servers: [ProxyServer], selected: Int, mixedPort: Int?, systemProxy: Bool, apiPort: Int?) -> Data {
        var outbounds: [[String: Any]] = servers.enumerated().compactMap { i, s in
            guard var o = try? JSONSerialization.jsonObject(with: Data(s.outbound.utf8)) as? [String: Any] else { return nil }
            o["tag"] = "s\(i)"
            return o
        }
        let tags = outbounds.compactMap { $0["tag"] as? String }
        outbounds.insert(["type": "selector", "tag": "proxy", "outbounds": tags, "default": "s\(selected)"], at: 0)
        outbounds.append(["type": "direct", "tag": "direct"])
        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": ["servers": [["type": "local", "tag": "local"]]],
            "outbounds": outbounds,
            "route": ["final": "proxy", "auto_detect_interface": true, "default_domain_resolver": "local"],
        ]
        if let port = mixedPort {
            config["inbounds"] = [["type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port,
                                   "set_system_proxy": systemProxy]]
        }
        if let api = apiPort {
            config["experimental"] = ["clash_api": ["external_controller": "127.0.0.1:\(api)"]]
        }
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: Self-check (run with Scripts/check-proxy-links.sh)

    static func selfCheck() {
        func out(_ s: ProxyServer?) -> [String: Any] {
            precondition(s != nil, "link failed to parse")
            return try! JSONSerialization.jsonObject(with: Data(s!.outbound.utf8)) as! [String: Any]
        }
        let vless = out(link("vless://11111111-2222-3333-4444-555555555555@example.com:443?type=ws&security=tls&sni=sni.example.com&path=%2Fws%3Fed%3D2048&host=cdn.example.com&fp=chrome#My%20Server"))
        precondition(vless["type"] as? String == "vless" && vless["server_port"] as? Int == 443)
        let ws = vless["transport"] as! [String: Any]
        precondition(ws["path"] as? String == "/ws" && ws["max_early_data"] as? Int == 2048)
        precondition((vless["tls"] as! [String: Any])["server_name"] as? String == "sni.example.com")
        precondition(link("vless://11111111-2222-3333-4444-555555555555@example.com:443#My%20Server")?.name == "My Server")

        let reality = out(link("vless://uuid@1.2.3.4:443?security=reality&pbk=PUBKEY&sid=ab&flow=xtls-rprx-vision&sni=www.apple.com"))
        let rtls = reality["tls"] as! [String: Any]
        precondition((rtls["reality"] as! [String: Any])["public_key"] as? String == "PUBKEY" && rtls["utls"] != nil)
        precondition(reality["flow"] as? String == "xtls-rprx-vision")

        let vmessJSON = #"{"v":"2","ps":"VM","add":"vm.example.com","port":"8443","id":"abc","aid":"0","net":"grpc","path":"svc","tls":"tls","sni":"vm.example.com"}"#
        let vm = out(link("vmess://" + Data(vmessJSON.utf8).base64EncodedString()))
        precondition(vm["server_port"] as? Int == 8443 && (vm["transport"] as! [String: Any])["service_name"] as? String == "svc")
        precondition(vm["tls"] != nil)

        let trojan = out(link("trojan://p%40ss@t.example.com:443?sni=t.example.com#T"))
        precondition(trojan["password"] as? String == "p@ss" && trojan["tls"] != nil)

        let ss1 = out(link("ss://" + Data("aes-128-gcm:testpass".utf8).base64EncodedString() + "@127.0.0.1:8388#SS"))
        precondition(ss1["method"] as? String == "aes-128-gcm" && ss1["password"] as? String == "testpass")
        let ss2 = out(link("ss://" + Data("chacha20-ietf-poly1305:pw@[::1]:8388".utf8).base64EncodedString() + "#Legacy"))
        precondition(ss2["server"] as? String == "::1" && ss2["password"] as? String == "pw")
        let ss3 = out(link("ss://2022-blake3-aes-128-gcm:a%2Bb%3D@h.example.com:1234/?plugin=obfs-local%3Bobfs%3Dhttp"))
        precondition(ss3["password"] as? String == "a+b=" && ss3["plugin"] as? String == "obfs-local")

        let hy = out(link("hy2://secret@h.example.com:443?sni=h.example.com&insecure=1&obfs=salamander&obfs-password=x"))
        precondition(hy["password"] as? String == "secret" && (hy["tls"] as! [String: Any])["insecure"] as? Bool == true)
        precondition((hy["obfs"] as! [String: Any])["type"] as? String == "salamander")

        let tuic = out(link("tuic://uuid:pw@t.example.com:443?congestion_control=bbr&alpn=h3"))
        precondition(tuic["uuid"] as? String == "uuid" && tuic["password"] as? String == "pw")

        precondition(link("vless://u@h.example.com:443?type=xhttp") == nil, "unsupported transport must be skipped")
        precondition(link("https://example.com") == nil)

        let sub = Data("trojan://a@x.example.com:443#A\nnot a link\nhy2://b@y.example.com:443#B".utf8).base64EncodedString()
        let parsed = parse(sub)
        precondition(parsed.servers.map(\.name) == ["A", "B"] && parsed.skipped == 1)

        let sb = parse(#"{"outbounds":[{"type":"selector","tag":"sel","outbounds":["x"]},{"type":"shadowsocks","tag":"x","server":"a","server_port":1,"method":"none","password":""},{"type":"direct","tag":"direct"}]}"#)
        precondition(sb.servers.count == 1 && sb.servers[0].name == "x" && !sb.servers[0].outbound.contains("\"tag\""))
        print("ProxyLinks self-check passed")
    }
}
