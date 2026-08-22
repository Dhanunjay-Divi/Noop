import Foundation
import WhoopStore

enum NutritionBarcodeLookupError: Error, Equatable, LocalizedError {
    case invalidBarcode
    case productNotFound
    case invalidResponse
    case serviceBusy
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidBarcode:
            return String(localized: "nutrition.barcode.error.invalid")
        case .productNotFound:
            return String(localized: "nutrition.barcode.error.not_found")
        case .invalidResponse:
            return String(localized: "nutrition.barcode.error.invalid_response")
        case .serviceBusy:
            return String(localized: "nutrition.barcode.error.rate_limited")
        case .requestFailed:
            return String(localized: "nutrition.barcode.error.network")
        }
    }
}

enum OpenFoodFactsParser {
    private struct Response: Decodable {
        let status: Int?
        let product: Product?
    }

    private struct Product: Decodable {
        let productName: String?
        let brands: String?
        let servingQuantity: Double?
        let servingQuantityUnit: String?
        let nutriments: Nutriments?

        enum CodingKeys: String, CodingKey {
            case productName = "product_name"
            case brands
            case servingQuantity = "serving_quantity"
            case servingQuantityUnit = "serving_quantity_unit"
            case nutriments
        }
    }

    private struct Nutriments: Decodable {
        let energyKcalServing: Double?
        let energyKcal100g: Double?
        let proteinsServing: Double?
        let proteins100g: Double?
        let carbohydratesServing: Double?
        let carbohydrates100g: Double?
        let fatServing: Double?
        let fat100g: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcalServing = "energy-kcal_serving"
            case energyKcal100g = "energy-kcal_100g"
            case proteinsServing = "proteins_serving"
            case proteins100g = "proteins_100g"
            case carbohydratesServing = "carbohydrates_serving"
            case carbohydrates100g = "carbohydrates_100g"
            case fatServing = "fat_serving"
            case fat100g = "fat_100g"
        }
    }

    static func parse(data: Data, barcode rawBarcode: String, now: Int) throws
        -> NutritionCatalogItemRow
    {
        guard let barcode = NutritionCatalogContract.normalizedBarcode(rawBarcode), now > 0 else {
            throw NutritionBarcodeLookupError.invalidBarcode
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NutritionBarcodeLookupError.invalidResponse
        }
        guard response.status == 1, let product = response.product else {
            throw NutritionBarcodeLookupError.productNotFound
        }
        let name = product.productName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            throw NutritionBarcodeLookupError.invalidResponse
        }

        let rawQuantity = finitePositive(product.servingQuantity)
        let hasServingNutrients = [
            product.nutriments?.energyKcalServing,
            product.nutriments?.proteinsServing,
            product.nutriments?.carbohydratesServing,
            product.nutriments?.fatServing,
        ].contains { finiteNonnegative($0) != nil }
        let quantity = rawQuantity ?? (hasServingNutrients ? 1 : 100)
        let unit = product.servingQuantityUnit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? (hasServingNutrients ? "serving" : "g")

        func nutrient(_ serving: Double?, _ per100g: Double?) -> Double? {
            if let serving = finiteNonnegative(serving) { return serving }
            guard let per100g = finiteNonnegative(per100g) else { return nil }
            return rawQuantity.map { per100g * $0 / 100 } ?? per100g
        }

        let nutriments = product.nutriments
        return try NutritionCatalogContract.validated(NutritionCatalogItemRow(
            id: try NutritionCatalogContract.barcodeID(barcode),
            kind: NutritionCatalogContract.foodKind,
            name: name,
            brand: product.brands,
            barcode: barcode,
            servingQuantity: quantity,
            servingUnit: unit,
            caloriesKcal: nutrient(
                nutriments?.energyKcalServing,
                nutriments?.energyKcal100g
            ),
            proteinG: nutrient(nutriments?.proteinsServing, nutriments?.proteins100g),
            carbsG: nutrient(
                nutriments?.carbohydratesServing,
                nutriments?.carbohydrates100g
            ),
            fatG: nutrient(nutriments?.fatServing, nutriments?.fat100g),
            mealType: "other",
            source: NutritionCatalogContract.openFoodFactsSource,
            isSaved: false,
            createdAt: now,
            updatedAt: now
        ))
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

actor OpenFoodFactsClient {
    static let shared = OpenFoodFactsClient()

    private static let minimumRequestInterval: TimeInterval = 4.1
    private static let userAgent =
        "NOOP/9.2.0 (https://github.com/Dhanunjay-Divi/Noop)"
    private var lastRequestAt: Date?

    func product(barcode rawBarcode: String, now: Date = Date()) async throws
        -> NutritionCatalogItemRow
    {
        guard let barcode = NutritionCatalogContract.normalizedBarcode(rawBarcode) else {
            throw NutritionBarcodeLookupError.invalidBarcode
        }
        if let lastRequestAt {
            let remaining = Self.minimumRequestInterval - now.timeIntervalSince(lastRequestAt)
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }
        lastRequestAt = Date()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "world.openfoodfacts.org"
        components.path = "/api/v2/product/\(barcode).json"
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: [
                    "code", "product_name", "brands", "serving_quantity",
                    "serving_quantity_unit", "nutriments",
                ].joined(separator: ",")
            ),
        ]
        guard let url = components.url else {
            throw NutritionBarcodeLookupError.invalidBarcode
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NutritionBarcodeLookupError.requestFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw NutritionBarcodeLookupError.invalidResponse
        }
        if http.statusCode == 429 {
            throw NutritionBarcodeLookupError.serviceBusy
        }
        guard (200...299).contains(http.statusCode) else {
            throw NutritionBarcodeLookupError.requestFailed
        }
        return try OpenFoodFactsParser.parse(
            data: data,
            barcode: barcode,
            now: Int(Date().timeIntervalSince1970)
        )
    }
}
