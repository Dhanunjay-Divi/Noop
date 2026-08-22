import XCTest
@testable import Strand

final class NutritionBarcodeLookupTests: XCTestCase {
    func testParsesServingNutrientsWithoutInventingMissingValues() throws {
        let item = try OpenFoodFactsParser.parse(
            data: Data(
                """
                {
                  "status": 1,
                  "product": {
                    "product_name": "Test yogurt",
                    "brands": "Example",
                    "serving_quantity": 150,
                    "serving_quantity_unit": "g",
                    "nutriments": {
                      "energy-kcal_serving": 120,
                      "proteins_serving": 12,
                      "fat_serving": 3.5
                    }
                  }
                }
                """.utf8
            ),
            barcode: "3017620422003",
            now: 1_777_000_000
        )

        XCTAssertEqual(item.id, "barcode:3017620422003")
        XCTAssertEqual(item.name, "Test yogurt")
        XCTAssertEqual(item.servingQuantity, 150)
        XCTAssertEqual(item.caloriesKcal, 120)
        XCTAssertEqual(item.proteinG, 12)
        XCTAssertNil(item.carbsG)
        XCTAssertEqual(item.fatG, 3.5)
    }

    func testScalesPerHundredGramValuesToServing() throws {
        let item = try OpenFoodFactsParser.parse(
            data: Data(
                """
                {
                  "status": 1,
                  "product": {
                    "product_name": "Test cereal",
                    "serving_quantity": 40,
                    "serving_quantity_unit": "g",
                    "nutriments": {
                      "energy-kcal_100g": 400,
                      "proteins_100g": 10,
                      "carbohydrates_100g": 70
                    }
                  }
                }
                """.utf8
            ),
            barcode: "12345678",
            now: 1_777_000_000
        )

        XCTAssertEqual(item.caloriesKcal, 160)
        XCTAssertEqual(item.proteinG, 4)
        XCTAssertEqual(item.carbsG, 28)
        XCTAssertNil(item.fatG)
    }

    func testRejectsNotFoundAndMalformedProducts() {
        XCTAssertThrowsError(try OpenFoodFactsParser.parse(
            data: Data(#"{"status":0}"#.utf8),
            barcode: "3017620422003",
            now: 1_777_000_000
        )) { error in
            XCTAssertEqual(error as? NutritionBarcodeLookupError, .productNotFound)
        }
        XCTAssertThrowsError(try OpenFoodFactsParser.parse(
            data: Data(#"{"status":1,"product":{"product_name":12}}"#.utf8),
            barcode: "3017620422003",
            now: 1_777_000_000
        )) { error in
            XCTAssertEqual(error as? NutritionBarcodeLookupError, .invalidResponse)
        }
    }
}
