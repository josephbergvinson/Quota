import Foundation

struct ProviderUsageAggregate: Sendable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var requests = 0
    var costUSD = 0.0

    mutating func add(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        requests: Int = 0,
        costUSD: Double = 0
    ) throws {
        guard
            inputTokens >= 0,
            cachedInputTokens >= 0,
            outputTokens >= 0,
            requests >= 0,
            costUSD.isFinite,
            costUSD >= 0
        else {
            throw ProviderError.invalidResponse
        }

        self.inputTokens = try checkedAdd(self.inputTokens, inputTokens)
        self.cachedInputTokens = try checkedAdd(self.cachedInputTokens, cachedInputTokens)
        self.outputTokens = try checkedAdd(self.outputTokens, outputTokens)
        self.requests = try checkedAdd(self.requests, requests)

        let updatedCost = self.costUSD + costUSD
        guard updatedCost.isFinite else {
            throw ProviderError.invalidResponse
        }
        self.costUSD = updatedCost
    }

    func totalTokens() throws -> Int {
        try checkedAdd(inputTokens, outputTokens)
    }
}

func checkedProviderSum(_ values: [Int]) throws -> Int {
    try values.reduce(0, checkedAdd)
}

func checkedProviderCostSum(_ left: Double, _ right: Double) throws -> Double {
    guard left.isFinite, right.isFinite, left >= 0, right >= 0 else {
        throw ProviderError.invalidResponse
    }
    let result = left + right
    guard result.isFinite else {
        throw ProviderError.invalidResponse
    }
    return result
}

private func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
    guard left >= 0, right >= 0 else {
        throw ProviderError.invalidResponse
    }
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow else {
        throw ProviderError.invalidResponse
    }
    return result
}
