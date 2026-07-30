import Foundation

// MARK: - Transaction

struct Transaction: Identifiable {
    let id = UUID()
    let date: Date
    let merchant: String
    let category: String
    let account: String
    /// Negative = money out, positive = money in.
    let amount: Decimal
}
