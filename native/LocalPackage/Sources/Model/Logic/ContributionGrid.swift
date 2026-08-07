import Foundation

// Port of src/lib/grid.ts — GitHub layout: 53+ columns, 7 rows, Sunday on
// top. col 0 row 0 = the Sunday on or before Jan 1 of `year`.

public struct GridCell: Sendable, Equatable {
    public var col: Int
    public var row: Int
    public var date: String
    public var inYear: Bool
    public var active: Bool
    public var tokens: Int64
    public var cost: Double
}

public struct GridLayout: Sendable, Equatable {
    public var cols: Int
    public var rows: Int  // 7
    public var cells: [GridCell]
    public var maxTokens: Int64
}

public enum ContributionGrid {
    public static func buildGrid(year: String, perDayMap: [String: PerDay]) -> GridLayout {
        let cal = Formatters.calendar
        guard let y = Int(year),
              let jan1 = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
              let dec31 = cal.date(from: DateComponents(year: y, month: 12, day: 31))
        else {
            return GridLayout(cols: 53, rows: 7, cells: [], maxTokens: 0)
        }

        // Calendar.weekday is Sun=1..Sat=7; JS getDay() is Sun=0..Sat=6.
        let dayOfWeek = cal.component(.weekday, from: jan1) - 1
        let start = Formatters.addDays(jan1, -dayOfWeek)

        let lastCol = Formatters.diffDays(dec31, start) / 7
        let cols = max(53, lastCol + 1)

        var cells: [GridCell] = []
        cells.reserveCapacity(cols * 7)
        var maxTokens: Int64 = 0
        for col in 0..<cols {
            for row in 0..<7 {
                let d = Formatters.addDays(start, col * 7 + row)
                let inYear = cal.component(.year, from: d) == y
                let dateStr = Formatters.isoDate(d)
                let entry = perDayMap[dateStr]
                let tokens = entry?.tokens ?? 0
                let cost = entry?.cost ?? 0
                let active = inYear && tokens > 0
                if active && tokens > maxTokens { maxTokens = tokens }
                cells.append(GridCell(col: col, row: row, date: dateStr,
                                      inYear: inYear, active: active,
                                      tokens: tokens, cost: cost))
            }
        }

        return GridLayout(cols: cols, rows: 7, cells: cells, maxTokens: maxTokens)
    }
}
