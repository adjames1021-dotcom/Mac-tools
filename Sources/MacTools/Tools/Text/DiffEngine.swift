import Foundation

enum DiffKind { case same, added, removed }

struct DiffLine: Identifiable {
    let id: Int
    let kind: DiffKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum DiffEngine {
    /// Line diff based on the longest common subsequence.
    static func diff(old: String, new: String, ignoreWhitespace: Bool = false, ignoreCase: Bool = false) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        func key(_ s: String) -> String {
            var k = s
            if ignoreWhitespace { k = k.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            if ignoreCase { k = k.lowercased() }
            return k
        }
        let ka = a.map(key)
        let kb = b.map(key)
        let n = ka.count
        let m = kb.count

        var result: [DiffLine] = []
        var nextID = 0
        func add(_ kind: DiffKind, _ text: String, _ o: Int?, _ nn: Int?) {
            result.append(DiffLine(id: nextID, kind: kind, text: text, oldNumber: o, newNumber: nn))
            nextID += 1
        }

        // Guard against huge inputs (the table is n*m).
        if n * m > 6_000_000 {
            for (i, line) in a.enumerated() { add(.removed, line, i + 1, nil) }
            for (j, line) in b.enumerated() { add(.added, line, nil, j + 1) }
            return result
        }

        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if ka[i] == kb[j] {
                        table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                    } else {
                        table[i * width + j] = max(table[(i + 1) * width + j], table[i * width + j + 1])
                    }
                }
            }
        }

        var i = 0
        var j = 0
        while i < n && j < m {
            if ka[i] == kb[j] {
                add(.same, b[j], i + 1, j + 1)
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                add(.removed, a[i], i + 1, nil)
                i += 1
            } else {
                add(.added, b[j], nil, j + 1)
                j += 1
            }
        }
        while i < n {
            add(.removed, a[i], i + 1, nil)
            i += 1
        }
        while j < m {
            add(.added, b[j], nil, j + 1)
            j += 1
        }
        return result
    }
}
