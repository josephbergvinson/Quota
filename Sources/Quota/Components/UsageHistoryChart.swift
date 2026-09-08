import Charts
import QuotaCore
import SwiftUI

enum UsageHistoryRange: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        case .all: "All"
        }
    }

    var description: String {
        switch self {
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .all: "All reported history"
        }
    }

    var dayCount: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .all: nil
        }
    }
}

struct UsageHistoryRangePicker: View {
    @Binding var selection: UsageHistoryRange
    var accessibilityLabel = "Analytics range"

    var body: some View {
        Picker("Analytics range", selection: $selection) {
            ForEach(UsageHistoryRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 190)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct UsageHistoryChart: View {
    private static let maximumXAxisLabelCount = 6
    private static let utcTimeZone = TimeZone(secondsFromGMT: 0)!
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        return calendar
    }()

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
    let dateInterval: DateInterval
    var tint: Color = .accentColor
    var rangeSelection: Binding<UsageHistoryRange>?
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
            if let rangeSelection {
                chartTitle
                if points.isEmpty {
                    UsageHistoryRangePicker(
                        selection: rangeSelection,
                        accessibilityLabel: "Usage history range"
                    )
                } else {
                    rangeAndChartControls(rangeSelection: rangeSelection)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        chartTitle
                        Spacer(minLength: 12)
                        chartControls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        chartTitle
                        chartControls
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            if points.isEmpty {
                ContentUnavailableView(
                    emptyRangeTitle,
                    systemImage: "chart.xyaxis.line"
                )
                .frame(height: 210)
            } else {
                usageChart
            }
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

    private func rangeAndChartControls(
        rangeSelection: Binding<UsageHistoryRange>
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                UsageHistoryRangePicker(
                    selection: rangeSelection,
                    accessibilityLabel: "Usage history range"
                )
                Spacer(minLength: 12)
                chartControls
            }
            VStack(alignment: .trailing, spacing: 8) {
                UsageHistoryRangePicker(
                    selection: rangeSelection,
                    accessibilityLabel: "Usage history range"
                )
                chartControls
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var chartTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Usage over time")
                .font(.headline)
            Text(chartDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chartControls: some View {
        HStack(spacing: 8) {
            if supportsCost {
                Picker("History metric", selection: $metric) {
                    ForEach(Metric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 140)
                .accessibilityLabel("History metric")
            }

            Picker("Chart style", selection: $presentation) {
                ForEach(Presentation.allCases) { presentation in
                    Text(presentation.rawValue).tag(presentation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 190)
            .accessibilityLabel("Chart style")
        }
    }

    private var usageChart: some View {
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
            AxisMarks(
                values: .stride(
                    by: .day,
                    count: xAxisDayStride,
                    roundLowerBound: false,
                    roundUpperBound: false,
                    calendar: Self.utcCalendar
                )
            ) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(
                    collisionResolution: .greedy(minimumSpacing: 8)
                ) {
                    if let date = value.as(Date.self) {
                        Text(date, format: xAxisDateFormat)
                    }
                }
            }
        }
        .chartXScale(
            domain: chartDomain,
            range: .plotDimension(startPadding: 24, endPadding: 24)
        )
        .environment(\.calendar, Self.utcCalendar)
        .environment(\.timeZone, Self.utcTimeZone)
        .frame(height: 210)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    private var chartDomain: ClosedRange<Date> {
        let upperBound = max(dateInterval.start, dateInterval.end.addingTimeInterval(-1))
        return dateInterval.start...upperBound
    }

    private var xAxisDayStride: Int {
        let start = Self.utcCalendar.startOfDay(for: dateInterval.start)
        let end = Self.utcCalendar.startOfDay(for: dateInterval.end)
        let dayCount = max(
            1,
            Self.utcCalendar.dateComponents([.day], from: start, to: end).day ?? 1
        )
        return max(
            1,
            Int(ceil(Double(dayCount) / Double(Self.maximumXAxisLabelCount)))
        )
    }

    private var xAxisDateFormat: Date.FormatStyle {
        var style = Date.FormatStyle(
            locale: .autoupdatingCurrent,
            calendar: Self.utcCalendar,
            timeZone: Self.utcTimeZone
        )
        .month(.abbreviated)
        .day()
        if crossesCalendarYear {
            style = style.year(.twoDigits)
        }
        return style
    }

    private var crossesCalendarYear: Bool {
        let lastDisplayedDay = max(
            dateInterval.start,
            dateInterval.end.addingTimeInterval(-1)
        )
        return Self.utcCalendar.component(.year, from: dateInterval.start)
            != Self.utcCalendar.component(.year, from: lastDisplayedDay)
    }

    private var emptyRangeTitle: String {
        guard let range = rangeSelection?.wrappedValue else {
            return "No usage reported in this period"
        }
        return switch range {
        case .sevenDays:
            "No usage reported in the last 7 days"
        case .thirtyDays:
            "No usage reported in the last 30 days"
        case .all:
            "No usage reported in retained history"
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
        let rangeDescription: String
        if let range = rangeSelection?.wrappedValue {
            rangeDescription = " for \(range.description.lowercased())"
        } else {
            rangeDescription = ""
        }
        return "\(presentation.rawValue) \(effectiveMetric.rawValue.lowercased()) usage chart\(rangeDescription)"
    }
}
