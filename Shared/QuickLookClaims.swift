import Foundation
import UniformTypeIdentifiers

/// What spacebar opens when you press Space in Finder, for the settings, About and installer text, and how another Quick Look
/// extension's claims overlap it. The claims themselves are in scripts/quicklook-types.txt (the app carries a copy); keep
/// `summary` in step with it.
enum QuickLookClaims {
    static let summary = "Markdown, folders, code and scripts, JSON, YAML, XML, TOML, property lists, logs, archives, disk images, and files with no extension"
    static let tagline = "Press Space. See everything."

    /// The kinds of file the claims fall into, by the section of quicklook-types.txt they are listed in.
    enum Group: String, CaseIterable {
        case markdown, code, data, text, archives, other

        var title: String {
            switch self {
            case .markdown: return "Markdown"
            case .code: return "code"
            case .data: return "data"
            case .text: return "text"
            case .archives: return "archives"
            case .other: return "files with no extension"
            }
        }

        /// The group a section heading of quicklook-types.txt names, or nil for any other comment.
        static func heading(_ line: String) -> Group? {
            let h = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let starts: [(String, Group)] = [("Markdown", .markdown), ("Source code", .code), ("Data", .data), ("Archives", .archives),
                                             ("Plain text", .text), ("Files with no extension", .other)]
            return starts.first { h.hasPrefix($0.0) }?.1
        }
    }

    struct Claim: Equatable {
        /// The type identifier the preview extension lists in QLSupportedContentTypes.
        let type: String
        /// The extensions a `declare` line names; empty for a `claim` (the system knows its extensions).
        let extensions: [String]
        let group: Group
    }

    /// The claims in quicklook-types.txt, each in the group of the section heading it is listed under (a heading is the first
    /// line of a comment paragraph).
    static func parse(_ text: String) -> [Claim] {
        var group = Group.other
        var afterBlank = true
        var claims: [Claim] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            defer { afterBlank = line.isEmpty }
            if line.hasPrefix("#") {
                if afterBlank, let g = Group.heading(line) { group = g }
                continue
            }
            let f = line.split(separator: " ", maxSplits: 3).map(String.init)
            if f.count == 2, f[0] == "claim" {
                claims.append(Claim(type: f[1], extensions: [], group: group))
            } else if f.count >= 3, f[0] == "declare" {
                let exts = f[1].split(separator: ",").map(String.init)
                claims.append(Claim(type: "md.spacebar.type.\(exts[0])", extensions: exts, group: group))
            }
        }
        return claims
    }

    /// The types another extension claims that are also spacebar's, by group. One of its types is spacebar's when it is the same
    /// type, when it names one of the same filename extensions (a vendor's own type, or a dyn.* type, for a file spacebar claims),
    /// or when it is a Markdown type of any vendor. A parent type (public.source-code, public.text) is not: Quick Look never
    /// routes a file by its parent type. `extensions` gives a type's filename extensions (`systemExtensions` in the app).
    static func overlap(ours: [Claim], theirs: [String], extensions: (String) -> [String]) -> [Group: [String]] {
        var byType: [String: Group] = [:]
        var byExt: [String: Group] = [:]
        for c in ours {
            byType[c.type.lowercased()] = c.group
            for e in c.extensions + extensions(c.type) where byExt[e.lowercased()] == nil { byExt[e.lowercased()] = c.group }
        }
        var out: [Group: [String]] = [:]
        for t in Set(theirs) where !t.lowercased().hasPrefix("md.spacebar") {
            let g = byType[t.lowercased()] ?? extensions(t).lazy.compactMap { byExt[$0.lowercased()] }.first
                ?? (t.lowercased().contains("markdown") ? .markdown : nil)
            if let g { out[g, default: []].append(t) }
        }
        for g in out.keys { out[g]!.sort() }
        return out
    }

    /// The filename extensions the system knows for a type, a dyn.* type's included.
    static func systemExtensions(_ type: String) -> [String] {
        UTType(type)?.tags[.filenameExtension] ?? []
    }

    /// "Markdown (2 types), code (42 types)": Markdown first, then the largest group.
    static func describe(_ overlap: [Group: [String]]) -> String {
        let order = { (g: Group) in Group.allCases.firstIndex(of: g)! }
        return overlap.sorted { a, b in
            if (a.key == .markdown) != (b.key == .markdown) { return a.key == .markdown }
            return a.value.count != b.value.count ? a.value.count > b.value.count : order(a.key) < order(b.key)
        }
        .map { "\($0.key.title) (\($0.value.count) \($0.value.count == 1 ? "type" : "types"))" }
        .joined(separator: ", ")
    }
}
