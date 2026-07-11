import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CustomTokenCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum CustomTokenCSV {
    static let header = "chain,contract,symbol,name,decimals,metadata_from_chain"

    struct Row: Sendable, Equatable {
        let line: Int
        let chain: SupportedChain
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
        let metadataFromChain: Bool
    }

    struct ParseResult: Sendable, Equatable {
        var rows: [Row] = []
        var errors: [String] = []
    }

    struct ImportSummary: Sendable, Equatable {
        var added: Int = 0
        var duplicates: Int = 0
        var failed: Int = 0
        var errors: [String] = []

        var title: String {
            added > 0 ? "CSV import complete" : "CSV import failed"
        }

        var message: String {
            var parts = [
                "Added: \(added)",
                "Duplicates: \(duplicates)",
                "Failed: \(failed)"
            ]
            if !errors.isEmpty {
                parts.append(errors.prefix(5).joined(separator: "\n"))
                if errors.count > 5 {
                    parts.append("And \(errors.count - 5) more row errors.")
                }
            }
            return parts.joined(separator: "\n")
        }
    }

    static func export(records: [CustomTokenRecord]) -> String {
        var lines = [header]
        let rows = records.sorted {
            if $0.chainRaw != $1.chainRaw { return $0.chainRaw < $1.chainRaw }
            return $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending
        }
        for token in rows {
            lines.append([
                token.chainRaw,
                token.contract,
                token.symbol,
                token.name,
                "\(token.decimals)",
                token.metadataFromChain ? "true" : "false"
            ].map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String, allowedChains: [SupportedChain]) -> ParseResult {
        let allowed = allowedChains.isEmpty ? Set(CustomTokenSupport.chains) : Set(allowedChains)
        let table = parseTable(text)
        guard !table.isEmpty else {
            return ParseResult(rows: [], errors: ["CSV file is empty."])
        }

        let header = table[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var index: [String: Int] = [:]
        for (offset, column) in header.enumerated() where index[column] == nil {
            index[column] = offset
        }
        let chainIndex = index["chain"] ?? index["network"]
        let contractIndex = index["contract"] ?? index["address"] ?? index["mint"]
        let symbolIndex = index["symbol"] ?? index["ticker"]
        let nameIndex = index["name"]
        let decimalsIndex = index["decimals"]
        let metadataIndex = index["metadata_from_chain"]

        guard let chainIndex, let contractIndex, let symbolIndex, let nameIndex, let decimalsIndex else {
            return ParseResult(
                rows: [],
                errors: ["CSV header must include chain, contract, symbol, name, decimals."]
            )
        }

        var result = ParseResult()
        for rowOffset in table.dropFirst().indices {
            let fields = table[rowOffset]
            let line = rowOffset + 1
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            func field(_ idx: Int?) -> String {
                guard let idx, idx < fields.count else { return "" }
                return fields[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let chainRaw = field(chainIndex)
            guard let chain = SupportedChain(rawValue: chainRaw), CustomTokenSupport.supports(chain) else {
                result.errors.append("Line \(line): unsupported chain '\(chainRaw)'.")
                continue
            }
            guard allowed.contains(chain) else {
                result.errors.append("Line \(line): \(chain.displayName) is not available for this wallet.")
                continue
            }

            let contractRaw = field(contractIndex)
            let contractValidation = validate(contract: contractRaw, chain: chain)
            guard case let .valid(contract) = contractValidation else {
                result.errors.append("Line \(line): invalid contract or mint for \(chain.displayName).")
                continue
            }

            let symbol = field(symbolIndex).uppercased()
            let name = field(nameIndex)
            guard !symbol.isEmpty, !name.isEmpty else {
                result.errors.append("Line \(line): symbol and name are required.")
                continue
            }

            guard let decimals = Int(field(decimalsIndex)), (0...255).contains(decimals) else {
                result.errors.append("Line \(line): decimals must be a number from 0 to 255.")
                continue
            }
            guard let metadataFromChain = bool(field(metadataIndex)) else {
                result.errors.append("Line \(line): metadata_from_chain must be true or false.")
                continue
            }

            result.rows.append(Row(
                line: line,
                chain: chain,
                contract: contract,
                symbol: symbol,
                name: name,
                decimals: decimals,
                metadataFromChain: metadataFromChain
            ))
        }
        return result
    }

    private static func validate(contract: String, chain: SupportedChain) -> ValidationResult {
        switch chain {
        case .solana:
            return ContractValidator.validateSolanaMint(contract)
        case .tron:
            return ContractValidator.validateTronContract(contract)
        default:
            return ContractValidator.validateEVM(contract)
        }
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0", "": return false
        default: return nil
        }
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func parseTable(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            consumeUnquoted(next, field: &field, row: &row, rows: &rows)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else {
                    consumeUnquoted(char, field: &field, row: &row, rows: &rows)
                }
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func consumeUnquoted(
        _ char: Character,
        field: inout String,
        row: inout [String],
        rows: inout [[String]]
    ) {
        switch char {
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(char)
        }
    }
}
