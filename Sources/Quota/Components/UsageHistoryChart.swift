import Charts
import QuotaCore
import SwiftUI

struct UsageHistoryChart: View {
    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "Cost"

        var id: String { rawValue }
    }

    enum Presentation: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case cumulative = "Cumulative"

        var id: String { rawValue }
    }

    let points: [DailyUsagePoint]
    var tint: Color = .accentColor
    var costIsComplete = true
    var costQualification: String?
    @State private var metric: Metric = .tokens
    @State private var presentation: Presentation = .daily

    private enum TokenCategory: String, CaseIterable {
        case uncachedInput = "Uncached input"
        case cachedInput = "Cached input"
        case output = "Output"
        case unattributed = "Unattributed"
    }

    private struct TokenSeriesPoint: Identifiable {
        let date: Date
        let category: TokenCategory
        let tokens: Int

        var id: String {
            "\(date.timeIntervalSinceReferenceDate)|\(category.rawValue)"
        }
    }

    private var supportsCost: Bool {
        costIsComplete && points.contains { $0.costUSD > 0 }
    }

    private var chartPoints: [DailyUsagePoint] {
        presentation == .cumulative ? UsageAnalytics.cumulativeUsage(points) : points
    }

    private var effectiveMetric: Metric {
        supportsCost ? metric : .tokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage over time")
                        .font(.headline)
                    Text(chartDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    if supportsCost {
                        Picker("History metric", selection: $metric) {
                            ForEach(Metric.allCases) { metric in
                                Text(metric.rawValue).tag(metric)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                        .accessibilityLabel("History metric")
                    }

                    Picker("Chart style", selection: $presentation) {
                        ForEach(Presentation.allCases) { presentation in
                            Text(presentation.rawValue).tag(presentation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel("Chart style")
                }
            }

            Chart {
                if effectiveMetric == .tokens, presentation == .daily, hasTokenBreakdown {
                    ForEach(tokenSeries) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Tokens", point.tokens)
                        )
                        .foregroundStyle(by: .value("Token type", point.category.rawValue))
                        .cornerRadius(2)
                    }
                } else if effectiveMetric == .tokens, presentation == .daily {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Total tokens", point.totalTokens)
                        )
                        .foregroundStyle(tint)
                        .cornerRadius(2)
                    }
                } else if effectiveMetric == .tokens {
                    ForEach(chartPoints) { point in
                        AreaMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cumulative tokens", point.totalTokens)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cumulative tokens", point.totalTokens)
                        )
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    ForEach(chartPoints) { point in
                        AreaMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cost", point.costUSD)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cost", point.costUSD)
                        )
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: activeTokenCategories.map(\.rawValue),
                range: activeTokenCategories.map(tokenColor)
            )
            .chartLegend(
                effectiveMetric == .tokens
                    && presentation == .daily
                    && hasTokenBreakdown
                    && activeTokenCategories.count > 1
                    ? .visible
                    : .hidden
            )
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if effectiveMetric == .cost, let amount = value.as(Double.self) {
                            Text(amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                        } else if let count = value.as(Int.self) {
                            Text(QuotaFormat.compactNumber(count))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, chartPoints.count / 6))) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 210)
            .accessibilityLabel(chartAccessibilityLabel)
        }
        .onChange(of: supportsCost) { _, supportsCost in
            if !supportsCost {
                metric = .tokens
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var tokenSeries: [TokenSeriesPoint] {
        points.flatMap { point in
            let values: [(TokenCategory, Int)] = [
                (.uncachedInput, max(0, point.inputTokens - point.cachedInputTokens)),
                (.cachedInput, point.cachedInputTokens),
                (.output, point.outputTokens),
                (.unattributed, point.unattributedTokens)
            ]
            return values.compactMap { value -> TokenSeriesPoint? in
                let (category, tokens) = value
                guard tokens > 0 else { return nil }
                return TokenSeriesPoint(date: point.date, category: category, tokens: tokens)
            }
        }
    }

    private var activeTokenCategories: [TokenCategory] {
        guard hasTokenBreakdown else { return [] }
        let categories = Set(tokenSeries.map(\.category))
        return TokenCategory.allCases.filter(categories.contains)
    }

    private var hasTokenBreakdown: Bool {
        points.contains {
            $0.inputTokens > 0 || $0.cachedInputTokens > 0 || $0.outputTokens > 0
        }
    }

    private func tokenColor(for category: TokenCategory) -> Color {
        switch category {
        case .uncachedInput:
            .blue
        case .cachedInput:
            .cyan
        case .output:
            .indigo
        case .unattributed:
            .secondary.opacity(0.65)
        }
    }

    private var chartDescription: String {
        let description = switch (effectiveMetric, presentation) {
        case (.tokens, .daily):
            hasTokenBreakdown
                ? "Provider-reported daily tokens, stacked by available type"
                : "Provider-reported daily total tokens"
        case (.tokens, .cumulative):
            "Running total of provider-reported tokens in the selected range"
        case (.cost, .daily):
            "Provider-reported daily cost"
        case (.cost, .cumulative):
            "Running total of provider-reported cost in the selected range"
        }
        if effectiveMetric == .cost, let costQualification {
            return "\(description) · \(costQualification)"
        }
        return description
    }

    private var chartAccessibilityLabel: String {
        "\(presentation.rawValue) \(effectiveMetric.rawValue.lowercased()) usage chart"
    }
}
