import QuotaCore
import SwiftUI

struct ResetPlannerView: View {
    @EnvironmentObject private var model: AppModel

    private var calendar: Calendar {
        Calendar.autoupdatingCurrent
    }

    private var resetInterval: DateInterval? {
        UsageAnalytics.forwardResetInterval(startingAt: model.now, calendar: calendar)
    }

    private var days: [Date] {
        guard let start = resetInterval?.start else { return [] }
        return (0..<8).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
    }

    private var events: [ResetEvent] {
        guard let resetInterval else { return [] }
        return UsageAnalytics.resetEvents(
            accounts: model.accounts,
            snapshots: model.state.snapshots,
            in: resetInterval
        )
        .filter { $0.resetsAt >= model.now }
    }

    private var availableNowWindows: [AvailableQuotaWindow] {
        UsageAnalytics.availableNowWindows(
            accounts: model.accounts,
            latestSnapshots: model.latestSnapshots
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                resetCalendar
            }
            .padding(24)
        }
        .navigationTitle("Reset Planner")
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today + next 7 days")
                    .font(.largeTitle.weight(.semibold))
                Text(rangeTitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeZone.autoupdatingCurrent.identifier.replacingOccurrences(of: "_", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
                .help("Reset times are shown in your Mac's current time zone")
        }
    }

    private var resetCalendar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 9) {
                ForEach(days, id: \.self) { day in
                    ResetDayColumn(
                        day: day,
                        events: events.filter { calendar.isDate($0.resetsAt, inSameDayAs: day) },
                        availableWindows: calendar.isDate(day, inSameDayAs: model.now)
                            ? availableNowWindows
                            : [],
                        calendar: calendar,
                        now: model.now
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var rangeTitle: String {
        guard
            let resetInterval,
            let lastDay = calendar.date(byAdding: .day, value: -1, to: resetInterval.end)
        else {
            return "Date range unavailable"
        }
        return "\(resetInterval.start.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

private struct ResetDayColumn: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let events: [ResetEvent]
    let availableWindows: [AvailableQuotaWindow]
    let calendar: Calendar
    let now: Date

    private var isToday: Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)
                    .textCase(.uppercase)
                Text(day.formatted(.dateTime.day()))
                    .font(.title2.weight(.semibold))
            }

            Divider()

            if events.isEmpty && availableWindows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.tertiary)
                    Text("No reported resets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ForEach(availableWindows) { window in
                    AvailableNowCard(
                        window: window,
                        now: now,
                        refreshFailed: didRefreshFail(for: window.account.id)
                    )
                }
                ForEach(events) { event in
                    ResetEventCard(
                        event: event,
                        now: now,
                        refreshFailed: didRefreshFail(for: event.account.id)
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 150, alignment: .topLeading)
        .frame(minHeight: 245, alignment: .topLeading)
        .background(
            isToday ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isToday ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        }
    }

    private func didRefreshFail(for accountID: UUID) -> Bool {
        if case .failed = model.refreshStates[accountID] {
            return true
        }
        return false
    }
}

private struct AvailableNowCard: View {
    let window: AvailableQuotaWindow
    let now: Date
    let refreshFailed: Bool

    private var isStale: Bool {
        refreshFailed
            || now.timeIntervalSince(window.capturedAt) > UsageAnalytics.capacityFreshnessInterval
            || window.capturedAt.timeIntervalSince(now) > 5 * 60
    }

    private var capacityStatus: CapacityStatus {
        isStale ? .stale : .freshStatus(forRemainingFraction: window.remainingFraction)
    }

    private var capacityDescription: String {
        isStale
            ? "\(QuotaFormat.percentage(window.remainingFraction)) last reported"
            : "\(QuotaFormat.percentage(window.remainingFraction)) left"
    }

    private var availabilityTitle: String {
        isStale ? "Last reported available" : "Available now"
    }

    private var activationDescription: String {
        isStale
            ? "Reset clock had not started at that reading"
            : "Reset clock starts on first use"
    }

    private var updateDescription: String {
        if refreshFailed {
            return "Refresh failed · last saved reading"
        }
        return "Updated \(window.capturedAt.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(availabilityTitle)
                .font(.caption.weight(.semibold))
            Text(window.account.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(window.windowName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(capacityDescription, systemImage: capacityStatus.indicatorSymbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(capacityStatus.color)
                .help(capacityStatus.label)
            Text(activationDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(updateDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(window.account.kind.provider.tintColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(window.account.kind.provider.tintColor)
                .frame(width: 3)
                .padding(.vertical, 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.account.displayName), \(window.windowName), \(availabilityTitle)")
        .accessibilityValue(
            "\(capacityDescription). \(activationDescription). \(updateDescription)."
        )
    }
}

private struct ResetEventCard: View {
    let event: ResetEvent
    let now: Date
    let refreshFailed: Bool

    private var isStale: Bool {
        refreshFailed
            || now.timeIntervalSince(event.capturedAt) > UsageAnalytics.capacityFreshnessInterval
            || event.capturedAt.timeIntervalSince(now) > 5 * 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.resetsAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            Text(event.account.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(event.windowName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(
                isStale
                    ? "\(QuotaFormat.percentage(event.remainingFraction)) last reported"
                    : "\(QuotaFormat.percentage(event.remainingFraction)) left",
                systemImage: capacityStatus.indicatorSymbolName
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(capacityStatus.color)
            .help(capacityStatus.label)
            Text("Updated \(event.capturedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(event.account.kind.provider.tintColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.account.kind.provider.tintColor)
                .frame(width: 3)
                .padding(.vertical, 5)
        }
        .accessibilityElement(children: .combine)
    }

    private var capacityStatus: CapacityStatus {
        isStale ? .stale : .freshStatus(forRemainingFraction: event.remainingFraction)
    }
}
