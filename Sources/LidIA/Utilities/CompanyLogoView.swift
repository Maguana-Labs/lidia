import SwiftUI

/// A company's logo without telling a third party which companies you meet.
///
/// By default it draws a monogram from the company name on this Mac and makes
/// no network request. Only when `AppSettings.fetchCompanyLogos` is on (off by
/// default) and Local-only mode is off does it ask the company's own website
/// for `/favicon.ico`. It never uses a favicon proxy such as Google's.
struct CompanyLogoView: View {
    let domain: String
    let name: String
    var size: CGFloat = 20

    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        Group {
            if let url = CompanyLogo.directFaviconURL(
                for: domain,
                fetchEnabled: settings?.fetchCompanyLogos ?? false,
                localOnly: settings?.localOnlyMode ?? true
            ) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().interpolation(.high).scaledToFit()
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let style = CompanyLogo.monogram(name: name, domain: domain)
        return RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color(hue: style.hue, saturation: 0.45, brightness: 0.75).gradient)
            .overlay {
                Text(style.initials)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
    }
}

enum CompanyLogo {
    struct Monogram: Equatable {
        let initials: String
        /// 0...1, stable for a given domain so colors don't shuffle between launches.
        let hue: Double
    }

    static func monogram(name: String, domain: String) -> Monogram {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials: String
        if words.count >= 2 {
            initials = String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            initials = String(first.prefix(2)).uppercased()
        } else {
            initials = String(domain.prefix(1)).uppercased()
        }
        // FNV-1a: deterministic across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in domain.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Monogram(initials: initials.isEmpty ? "?" : initials, hue: Double(hash % 360) / 360)
    }

    /// The company's own favicon URL, or `nil` when fetching is off, Local-only
    /// mode is on, or the domain isn't a plain host name.
    static func directFaviconURL(for domain: String, fetchEnabled: Bool, localOnly: Bool) -> URL? {
        guard fetchEnabled, !localOnly, isPlainHostName(domain) else { return nil }
        return URL(string: "https://\(domain.lowercased())/favicon.ico")
    }

    /// Letters, digits, hyphens and dots only, with at least one dot. Rules
    /// out paths, ports, credentials and IP-literal tricks.
    static func isPlainHostName(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard domain.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        // Reject bare IPv4 addresses: they'd point at a machine, not a company.
        let labels = domain.split(separator: ".")
        return !labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
