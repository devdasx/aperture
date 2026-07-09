import CryptoKit
import Foundation

enum TronAddressCodec {
    private static let tronPrefix: UInt8 = 0x41
    private static let base58Alphabet = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    static let nullAddress = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"

    static func normalizeAddress(_ input: String) -> TronAddressValidationResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid(.empty) }

        if let normalizedHex = normalizeHexAddress(trimmed) {
            return .valid(normalizedHex)
        }

        if trimmed.unicodeScalars.contains(where: { !base58Alphabet.contains($0) }) {
            return .invalid(.invalidCharacter)
        }
        guard let decoded = Base58.decodeBytes(trimmed) else {
            return .invalid(.notBase58)
        }
        guard decoded.count == 25 else {
            return .invalid(.wrongLength)
        }

        let payload = Array(decoded.prefix(21))
        guard payload.first == tronPrefix else {
            return .invalid(.wrongLength)
        }
        let checksum = Array(decoded.suffix(4))
        guard checksum == checksumBytes(for: payload) else {
            return .invalid(.invalidChecksum)
        }
        return .valid(Base58.encode(Data(payload + checksum)))
    }

    static func hexPayloadWithoutPrefix(_ address: String) -> String? {
        guard case let .valid(normalized) = normalizeAddress(address),
              let decoded = Base58.decodeBytes(normalized),
              decoded.count == 25 else {
            return nil
        }
        let payload = Array(decoded.prefix(21))
        guard payload.first == tronPrefix else { return nil }
        return payload.dropFirst().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeHexAddress(_ input: String) -> String? {
        let body: String
        if input.hasPrefix("0x") || input.hasPrefix("0X") {
            body = String(input.dropFirst(2))
        } else {
            body = input
        }
        guard body.count == 42 else { return nil }
        let hexAlphabet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard !body.unicodeScalars.contains(where: { !hexAlphabet.contains($0) }) else {
            return nil
        }
        guard body.lowercased().hasPrefix("41") else { return nil }
        var payload: [UInt8] = []
        payload.reserveCapacity(21)
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2)
            guard let byte = UInt8(body[index..<next], radix: 16) else { return nil }
            payload.append(byte)
            index = next
        }
        return Base58.encode(Data(payload + checksumBytes(for: payload)))
    }

    private static func checksumBytes(for payload: [UInt8]) -> [UInt8] {
        let first = SHA256.hash(data: Data(payload))
        let second = SHA256.hash(data: Data(first))
        return Array(second.prefix(4))
    }
}

enum TronAddressValidationResult: Sendable, Equatable {
    case valid(String)
    case invalid(ValidationError)
}
