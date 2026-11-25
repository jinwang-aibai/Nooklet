import EventKit
import SwiftUI

@MainActor
struct StatusCalendar: View {
    static let preferredHeight: CGFloat = 510
    private static let dayHeight: CGFloat = 40

    private struct ScheduleItem: Identifiable {
        let id: String
        let title: String
        let time: String
        let calendar: String
        let color: Color
    }

    @State private var month = Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var store: EKEventStore?
    @State private var authorization = EKEventStore.authorizationStatus(for: .event)
    @State private var markers: [Date: [Color]] = [:]
    @State private var schedule: [Date: [ScheduleItem]] = [:]
    @State private var requesting = false
    private let calendar = Calendar(identifier: .gregorian)
    private let lunar = Calendar(identifier: .chinese)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var secondary: Color { Color(nsColor: ToolboxAppearance.secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(month.formatted(.dateTime.year().month().locale(L10n.locale)))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                calendarButton(L10n.text("上个月"), symbol: "chevron.left") { changeMonth(-1) }
                Button {
                    select(calendar.startOfDay(for: Date()))
                } label: {
                    Text(L10n.text("今天")).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 5).frame(height: 21)
                }
                .buttonStyle(ToolIconButton())
                calendarButton(L10n.text("下个月"), symbol: "chevron.right") { changeMonth(1) }
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
                }
                ForEach(monthDates, id: \.self) { date in dayButton(date) }
            }
            Rectangle().fill(Color(nsColor: ToolboxAppearance.rule)).frame(height: 1)
                .accessibilityHidden(true)
            HStack {
                Label(L10n.text("近期日程"), systemImage: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let end = calendar.date(byAdding: .day, value: 2, to: selected) {
                    Text(L10n.text("%@至%@", shortDate(selected), shortDate(end))).font(.system(size: 10.5)).foregroundStyle(secondary)
                }
            }
            scheduleBody
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolboxCard(radius: 12)
        .onAppear { refreshSchedule() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in refreshSchedule() }
    }

    private var weekdays: [String] {
        if L10n.language == .simplifiedChinese { return "日一二三四五六".map(String.init) }
        var localized = calendar
        localized.locale = L10n.locale
        return localized.shortStandaloneWeekdaySymbols
    }

    private var monthDates: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let offset = calendar.component(.weekday, from: interval.start) - 1
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: interval.start) }
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(date)
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let day = calendar.component(.day, from: date)
        let lunarDay = lunarLabel(date)
        let dots = markers[date] ?? []
        return Button {
            select(date)
        } label: {
            VStack(spacing: 0) {
                Text("\(day)").font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text(lunarDay).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 3, height: 3)
                    }
                }
                .frame(height: 4)
            }
            .padding(.vertical, 4)
            .opacity(inMonth ? 1 : 0.70)
            .frame(maxWidth: .infinity, minHeight: Self.dayHeight)
            .background(isToday ? Color(nsColor: ToolboxAppearance.selection) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: ToolboxAppearance.blue), lineWidth: 1.4)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(ToolIconButton())
        .accessibilityLabel(L10n.text("%@，农历%@%@", shortDate(date), lunarDay, isToday ? L10n.text("，今天") : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var scheduleBody: some View {
        if authorization == .fullAccess {
            if schedule.isEmpty {
                Text(L10n.text("这三天没有日程")).font(.caption).foregroundStyle(secondary)
                    .padding(.vertical, 5)
            } else {
                ForEach(schedule.keys.sorted(), id: \.self) { date in
                    scheduleHeading(date)
                    ForEach(schedule[date] ?? []) { event in scheduleRow(event) }
                }
            }
        } else if authorization == .notDetermined || authorization == .writeOnly {
            Button(L10n.text("读取系统日程…"), action: requestAccess).disabled(requesting).controlSize(.small)
        } else {
            Text(L10n.text("可在系统设置的「隐私与安全性 → 日历」中允许读取日程。"))
                .font(.caption).foregroundStyle(secondary)
        }
    }

    private func scheduleHeading(_ date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        return HStack(spacing: 8) {
            Text("\(calendar.component(.day, from: date))").font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 30, height: 29)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: ToolboxAppearance.blue), lineWidth: 1.4) }
            VStack(alignment: .leading, spacing: 1) {
                Text(isToday ? L10n.text("今天") : date.formatted(.dateTime.weekday(.wide).locale(L10n.locale)))
                    .font(.system(size: 11, weight: .semibold))
                Text(lunarLabel(date, includeMonth: true)).font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer()
            Text(shortDate(date)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(secondary)
        }
        .accessibilityElement(children: .combine)
        .padding(.top, 2)
    }

    private func scheduleRow(_ event: ScheduleItem) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 27)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.time) · \(event.calendar)").font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color(nsColor: ToolboxAppearance.raised), in: RoundedRectangle(cornerRadius: 7))
        .help(event.title)
        .accessibilityElement(children: .combine)
    }

    private func calendarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 21, height: 21)
        }
        .buttonStyle(ToolIconButton()).accessibilityLabel(title).help(title)
    }

    private func select(_ date: Date) {
        if !calendar.isDate(date, equalTo: month, toGranularity: .month) { month = date }
        selected = date
        refreshSchedule()
    }

    private func changeMonth(_ offset: Int) {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let target = calendar.date(byAdding: .month, value: offset, to: start) else { return }
        select(target)
    }

    private func requestAccess() {
        guard !requesting else { return }
        requesting = true
        if store == nil { store = EKEventStore() }
        Task { @MainActor in
            defer { requesting = false }
            if (try? await store?.requestFullAccessToEvents()) == true { store?.reset() }
            refreshSchedule()
        }
    }

    private func refreshSchedule() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        let dates = monthDates
        guard authorization == .fullAccess, let first = dates.first, let last = dates.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            schedule = [:]
            markers = [:]
            return
        }
        if store == nil { store = EKEventStore() }
        guard let store else { return }
        let agendaDays = (0..<3).compactMap { calendar.date(byAdding: .day, value: $0, to: selected) }
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let timeFormat = Date.FormatStyle().hour().minute().locale(L10n.locale)
        var dots: [Date: [Color]] = [:]
        var agenda: [Date: [ScheduleItem]] = [:]
        for date in dates {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { continue }
            let dayEvents = events.filter { $0.startDate < tomorrow && $0.endDate > date }
            dots[date] = dayEvents.prefix(3).map { Color(cgColor: $0.calendar.cgColor) }
            if agendaDays.contains(date), !dayEvents.isEmpty {
                agenda[date] = dayEvents.prefix(6).map { event in
                    let time = event.isAllDay ? L10n.text("全天") : event.startDate < date ? L10n.text("持续中") : event.startDate.formatted(timeFormat)
                    return ScheduleItem(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                                        title: event.title ?? L10n.text("未命名日程"), time: time, calendar: event.calendar.title,
                                        color: Color(cgColor: event.calendar.cgColor))
                }
            }
        }
        markers = dots
        schedule = agenda
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(L10n.locale))
    }

    private func lunarLabel(_ date: Date, includeMonth: Bool = false) -> String {
        let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
        let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        guard let day = parts.day, days.indices.contains(day - 1),
              let month = parts.month, months.indices.contains(month - 1) else { return "" }
        if L10n.language == .english {
            return day == 1 || includeMonth ? "\(month)/\(day)" : "\(day)"
        }
        let monthLabel = (parts.isLeapMonth == true ? "闰" : "") + months[month - 1] + "月"
        if includeMonth { return monthLabel + days[day - 1] }
        return day == 1 ? monthLabel : days[day - 1]
    }
}
