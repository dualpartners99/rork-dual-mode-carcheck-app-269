import Foundation

nonisolated struct BINAPIResponse: Codable, Sendable {
    let valid: Bool?
    let card: BINCardInfo?
    let issuer: BINIssuerInfo?
    let country: BINCountryInfo?
}

nonisolated struct BINCardInfo: Codable, Sendable {
    let bin: String?
    let scheme: String?
    let type: String?
    let category: String?
}

nonisolated struct BINIssuerInfo: Codable, Sendable {
    let name: String?
    let url: String?
    let tel: String?
}

nonisolated struct BINCountryInfo: Codable, Sendable {
    let name: String?
    let alpha_2_code: String?
}

actor BINLookupService {
    static let shared = BINLookupService()
    private var cache: [String: PPSRBINData] = [:]

    func lookup(bin: String) async -> PPSRBINData {
        let prefix = String(bin.prefix(6))
        if let cached = cache[prefix] {
            return cached
        }

        let data = PPSRBINData(bin: prefix)

        guard let url = URL(string: "https://api.freebinchecker.com/bin/\(prefix)") else {
            cache[prefix] = data
            return data
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                cache[prefix] = data
                return data
            }

            let decoded = try JSONDecoder().decode(BINAPIResponse.self, from: responseData)

            await MainActor.run {
                data.scheme = decoded.card?.scheme ?? ""
                data.type = decoded.card?.type ?? ""
                data.category = decoded.card?.category ?? ""
                data.issuer = decoded.issuer?.name ?? ""
                data.country = decoded.country?.name ?? ""
                data.countryCode = decoded.country?.alpha_2_code ?? ""
                data.isLoaded = true
            }

            cache[prefix] = data
        } catch {
            cache[prefix] = data
        }

        return data
    }
}
