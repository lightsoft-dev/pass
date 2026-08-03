import Foundation

/// Resolves plain-text HTTP(S) links against terminal cells rather than String indices.
/// Terminal columns are the source of truth: a grapheme may occupy two cells and an NSString
/// range may occupy a different number of UTF-16 code units.
enum TerminalLinkResolver {
    struct Row: Equatable {
        let index: Int
        let cells: [Character?]
        /// True when this row is a soft-wrapped continuation of the preceding row.
        let joinsPrevious: Bool
    }

    struct CellPosition: Equatable {
        let row: Int
        let column: Int
    }

    struct CellRange: Equatable {
        let row: Int
        let startColumn: Int
        /// Half-open terminal column, matching Swift's Range convention.
        let endColumn: Int
    }

    struct Match: Equatable {
        let url: URL
        let ranges: [CellRange]
    }

    static func match(rows: [Row], at point: CellPosition) -> Match? {
        let rows = rows.sorted { $0.index < $1.index }
        guard let rowOffset = rows.firstIndex(where: { $0.index == point.row }),
              rows[rowOffset].cells.indices.contains(point.column),
              isURLCharacter(rows[rowOffset].cells[point.column])
        else { return nil }

        let pointed = Cursor(rowOffset: rowOffset, column: point.column)
        var start = pointed
        while let previous = previousCursor(before: start, rows: rows),
              isURLCharacter(character(at: previous, rows: rows)) {
            start = previous
        }

        var characters: [Character] = []
        var positions: [CellPosition] = []
        var cursor: Cursor? = start
        while let current = cursor,
              let character = character(at: current, rows: rows),
              isURLCharacter(character) {
            characters.append(character)
            positions.append(CellPosition(
                row: rows[current.rowOffset].index,
                column: current.column
            ))
            cursor = nextCursor(after: current, rows: rows)
        }

        guard let pointedOffset = positions.firstIndex(of: point),
              let schemeOffset = schemeStart(in: characters, noLaterThan: pointedOffset)
        else { return nil }

        characters.removeFirst(schemeOffset)
        positions.removeFirst(schemeOffset)
        trimTrailingProse(from: &characters, positions: &positions)

        guard positions.contains(point) else { return nil }
        let raw = String(characters)
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else { return nil }

        return Match(url: url, ranges: cellRanges(for: positions))
    }

    private struct Cursor: Equatable {
        let rowOffset: Int
        let column: Int
    }

    private static func character(at cursor: Cursor, rows: [Row]) -> Character? {
        guard rows.indices.contains(cursor.rowOffset),
              rows[cursor.rowOffset].cells.indices.contains(cursor.column)
        else { return nil }
        return rows[cursor.rowOffset].cells[cursor.column]
    }

    private static func previousCursor(before cursor: Cursor, rows: [Row]) -> Cursor? {
        if cursor.column > 0 {
            return Cursor(rowOffset: cursor.rowOffset, column: cursor.column - 1)
        }
        guard cursor.rowOffset > 0,
              rows[cursor.rowOffset].joinsPrevious,
              rows[cursor.rowOffset - 1].index + 1 == rows[cursor.rowOffset].index,
              let lastColumn = rows[cursor.rowOffset - 1].cells.indices.last
        else { return nil }
        return Cursor(rowOffset: cursor.rowOffset - 1, column: lastColumn)
    }

    private static func nextCursor(after cursor: Cursor, rows: [Row]) -> Cursor? {
        let nextColumn = cursor.column + 1
        if rows[cursor.rowOffset].cells.indices.contains(nextColumn) {
            return Cursor(rowOffset: cursor.rowOffset, column: nextColumn)
        }
        let nextRowOffset = cursor.rowOffset + 1
        guard rows.indices.contains(nextRowOffset),
              rows[nextRowOffset].joinsPrevious,
              rows[cursor.rowOffset].index + 1 == rows[nextRowOffset].index,
              let firstColumn = rows[nextRowOffset].cells.indices.first
        else { return nil }
        return Cursor(rowOffset: nextRowOffset, column: firstColumn)
    }

    /// Plain-text auto-linking is deliberately ASCII-only. Unicode URLs remain available via
    /// OSC 8, while Korean particles such as `에서` cannot be mistaken for part of a host.
    private static func isURLCharacter(_ character: Character?) -> Bool {
        guard let character,
              character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.value < 128
        else { return false }

        switch scalar.value {
        case 48...57, 65...90, 97...122: // alphanumeric
            return true
        default:
            return "-._~:/?#[]@!$&()*+,;=%".unicodeScalars.contains(scalar)
        }
    }

    private static func schemeStart(
        in characters: [Character],
        noLaterThan pointedOffset: Int
    ) -> Int? {
        guard !characters.isEmpty else { return nil }
        let schemes = [Array("https://"), Array("http://")]
        var result: Int?
        for offset in 0...min(pointedOffset, characters.count - 1) {
            for scheme in schemes
                where offset + scheme.count <= characters.count
                    && Array(characters[offset..<(offset + scheme.count)]) == scheme {
                result = offset
                break
            }
        }
        return result
    }

    private static func trimTrailingProse(
        from characters: inout [Character],
        positions: inout [CellPosition]
    ) {
        while let last = characters.last {
            if ".,;:!?".contains(last) || isUnmatchedClosingDelimiter(last, in: characters) {
                characters.removeLast()
                positions.removeLast()
            } else {
                break
            }
        }
    }

    private static func isUnmatchedClosingDelimiter(
        _ character: Character,
        in characters: [Character]
    ) -> Bool {
        let pair: (open: Character, close: Character)?
        switch character {
        case ")": pair = ("(", ")")
        case "]": pair = ("[", "]")
        case "}": pair = ("{", "}")
        default: pair = nil
        }
        guard let pair else { return false }
        return characters.filter { $0 == pair.close }.count
            > characters.filter { $0 == pair.open }.count
    }

    private static func cellRanges(for positions: [CellPosition]) -> [CellRange] {
        var ranges: [CellRange] = []
        for position in positions {
            if let last = ranges.last,
               last.row == position.row,
               last.endColumn == position.column {
                ranges[ranges.count - 1] = CellRange(
                    row: last.row,
                    startColumn: last.startColumn,
                    endColumn: position.column + 1
                )
            } else {
                ranges.append(CellRange(
                    row: position.row,
                    startColumn: position.column,
                    endColumn: position.column + 1
                ))
            }
        }
        return ranges
    }
}
