import Foundation

extension Double {
    var currencyString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "$%.2f", self)
    }

    /// Same as `currencyString`, but prefixes a "+" for positive values (negatives already show "-").
    func currencyString(showSign: Bool) -> String {
        guard showSign, self > 0 else { return currencyString }
        return "+" + currencyString
    }
}
