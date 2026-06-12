import Testing
import Foundation
@testable import Aperture

/// Pure-function tests for `EVMChainAdapter`'s Multicall3 encoder /
/// decoder. No network — the codec is the part of the EVM fetching
/// stack that's most amenable to deterministic unit tests, and it's
/// the part whose bugs are most expensive (a wrong decode silently
/// reports a phantom balance, the 2026-06-11 length-word bug that
/// already cost us once).
struct EVMMulticall3CodecTests {

    // MARK: - Encoder

    @Test("Multicall3 encoder produces the correct selector + outer offset")
    func encoderSelectorAndOuterOffset() throws {
        let holder = "0x52908400098527886E0F7030069857D2E4169EE7"
        let hex = EVMChainAdapter.encodeMulticall3Aggregate3(
            holder: holder,
            tokenContracts: ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"]
        )
        // selector `0x82ad56cb`
        #expect(hex.hasPrefix("0x82ad56cb"), "Encoder missing aggregate3 selector")
        // outer offset (0x20) at bytes 4..36 of the calldata (chars 10..74)
        let outerOffset = String(hex.dropFirst(10).prefix(64))
        #expect(
            outerOffset == String(repeating: "0", count: 62) + "20",
            "Encoder outer offset wrong — got \(outerOffset)"
        )
    }

    @Test("Multicall3 encoder produces the correct array length word")
    func encoderArrayLength() throws {
        let holder = "0x52908400098527886E0F7030069857D2E4169EE7"
        // 3 contracts — array length should be 3 (0x03).
        let hex = EVMChainAdapter.encodeMulticall3Aggregate3(
            holder: holder,
            tokenContracts: [
                "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                "0xdAC17F958D2ee523a2206206994597C13D831ec7",
                "0x6B175474E89094C44Da98b954EedeAC495271d0F"
            ]
        )
        // After `0x` + selector (8) + outer offset (64) = chars 10..74,
        // the length word lives at chars 74..138.
        let lengthStart = hex.index(hex.startIndex, offsetBy: 74)
        let lengthEnd = hex.index(lengthStart, offsetBy: 64)
        let lengthHex = String(hex[lengthStart..<lengthEnd])
        let n = Int(lengthHex, radix: 16) ?? -1
        #expect(n == 3, "Encoder length-N wrong — got \(n) (\(lengthHex))")
    }

    @Test("Multicall3 encoder is deterministic for the same inputs")
    func encoderDeterministic() throws {
        let holder = "0x52908400098527886E0F7030069857D2E4169EE7"
        let contracts = ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"]
        let a = EVMChainAdapter.encodeMulticall3Aggregate3(holder: holder, tokenContracts: contracts)
        let b = EVMChainAdapter.encodeMulticall3Aggregate3(holder: holder, tokenContracts: contracts)
        #expect(a == b, "Encoder is non-deterministic")
    }

    @Test("Multicall3 encoder lowercases EVM hex (case-insensitive ABI)")
    func encoderLowercases() throws {
        let holderUpper = "0x52908400098527886E0F7030069857D2E4169EE7"
        let holderLower = "0x52908400098527886e0f7030069857d2e4169ee7"
        let a = EVMChainAdapter.encodeMulticall3Aggregate3(holder: holderUpper, tokenContracts: ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"])
        let b = EVMChainAdapter.encodeMulticall3Aggregate3(holder: holderLower, tokenContracts: ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"])
        #expect(a == b, "Encoder should be case-insensitive for the holder")
    }

    // MARK: - Decoder

    @Test("Multicall3 decoder rejects empty input → all-nil")
    func decoderEmpty() throws {
        let result = EVMChainAdapter.decodeMulticall3Result("", expectedCount: 5)
        #expect(result.count == 5, "Decoder should return expectedCount nil entries")
        #expect(result.allSatisfy { $0 == nil }, "Empty input should produce all-nil")
    }

    @Test("Multicall3 decoder rejects too-short input → all-nil")
    func decoderTooShort() throws {
        // Less than 128 hex chars (the outer offset + length-N).
        let stub = String(repeating: "0", count: 64)
        let result = EVMChainAdapter.decodeMulticall3Result(stub, expectedCount: 3)
        #expect(result.count == 3, "Decoder should return expectedCount nil entries")
        #expect(result.allSatisfy { $0 == nil }, "Truncated input should produce all-nil")
    }

    @Test("Multicall3 decoder rejects mismatched length-N → all-nil")
    func decoderLengthMismatch() throws {
        // Outer offset (0x20) + N (5) + the rest doesn't matter.
        let outerOffset = String(repeating: "0", count: 62) + "20"
        let lengthHex   = String(repeating: "0", count: 63) + "5"   // N = 5
        let blob = outerOffset + lengthHex + String(repeating: "0", count: 256 * 5)
        // Decoder is asked for expectedCount=3 but the blob says 5.
        let result = EVMChainAdapter.decodeMulticall3Result(blob, expectedCount: 3)
        #expect(result.allSatisfy { $0 == nil }, "Length mismatch should produce all-nil")
    }

    @Test("Multicall3 decoder reads a successful 1-USDC balance correctly")
    func decoderSingleSuccess() throws {
        // Build a 1-item response with returndata = 32-byte uint256 of 1_000_000
        // (1 USDC, since USDC has 6 decimals).
        //
        // Layout:
        //   outer offset (32B) = 0x20
        //   length N (32B)     = 1
        //   item offset (32B)  = 0x20 (pointing to first item from array data start)
        //   bool success (32B) = 1
        //   bytes offset (32B) = 0x40 (offset from item start to bytes)
        //   bytes length (32B) = 0x20 (32 bytes of returndata = one uint256)
        //   uint256 value (32B)= 1_000_000
        let outerOffset = pad32(0x20)
        let length      = pad32(1)
        let itemOffset  = pad32(0x20)
        let success     = pad32(1)
        let bytesOffset = pad32(0x40)
        let bytesLength = pad32(0x20)
        let value       = pad32(1_000_000)
        let blob = outerOffset + length + itemOffset + success + bytesOffset + bytesLength + value

        let result = EVMChainAdapter.decodeMulticall3Result(blob, expectedCount: 1)
        #expect(result.count == 1)
        let balance = result.first ?? nil
        #expect(balance == Decimal(1_000_000), "Expected raw balance 1_000_000, got \(String(describing: balance))")
    }

    @Test("Multicall3 decoder reads `success: false` → nil for that item")
    func decoderItemFailure() throws {
        // success = 0 means the item's `balanceOf` call reverted.
        let outerOffset = pad32(0x20)
        let length      = pad32(1)
        let itemOffset  = pad32(0x20)
        let success     = pad32(0)
        let bytesOffset = pad32(0x40)
        let bytesLength = pad32(0x20)
        let value       = pad32(1_000_000)  // ignored when success=0
        let blob = outerOffset + length + itemOffset + success + bytesOffset + bytesLength + value

        let result = EVMChainAdapter.decodeMulticall3Result(blob, expectedCount: 1)
        #expect(result.count == 1)
        #expect(result.first ?? Decimal(-1) == nil, "Failed item should be nil")
    }

    @Test("Multicall3 decoder rejects items with empty returndata → nil (2026-06-11 phantom-balance fix)")
    func decoderEmptyReturndata() throws {
        // `balanceOf` against an address with no code on this chain
        // succeeds with EMPTY returndata. The item is then only the
        // three fixed words (length = 0) — the old fixed read at
        // itemStart + 192 consumed the NEXT item's success flag
        // (0x…01), fabricating a phantom 1-base-unit balance the user
        // never owned. The fix: require the length word to declare
        // >= 32 bytes of returndata.
        let outerOffset = pad32(0x20)
        let length      = pad32(2)
        // Two item offsets pointing to consecutive items in the data area.
        // Item 0 starts at offset 0x40 from array data start.
        let item0Offset = pad32(0x40)
        // Item 1 starts at offset 0xA0 (after item 0's 3 fixed words = 96 bytes).
        let item1Offset = pad32(0xA0)
        // Item 0: success=1, byteOffset=0x40, byteLength=0 (empty returndata).
        let item0Success = pad32(1)
        let item0BytesOffset = pad32(0x40)
        let item0BytesLength = pad32(0)
        // Item 1: success=1, byteOffset=0x40, byteLength=32, value=999.
        let item1Success = pad32(1)
        let item1BytesOffset = pad32(0x40)
        let item1BytesLength = pad32(0x20)
        let item1Value = pad32(999)
        let blob = outerOffset + length + item0Offset + item1Offset
            + item0Success + item0BytesOffset + item0BytesLength
            + item1Success + item1BytesOffset + item1BytesLength + item1Value

        let result = EVMChainAdapter.decodeMulticall3Result(blob, expectedCount: 2)
        #expect(result.count == 2)
        // Item 0 should be nil (empty returndata).
        #expect(result[0] == nil, "Empty returndata item should be nil, got \(String(describing: result[0]))")
        // Item 1 should be 999.
        #expect(result[1] == Decimal(999), "Item 1 should be 999, got \(String(describing: result[1]))")
    }

    // MARK: - Helpers

    /// Pad an integer to a 32-byte (64 hex char) big-endian hex string.
    /// Local helper so the test doesn't reach for the adapter's
    /// `pad32` — keeps tests independent of the implementation.
    private func pad32(_ value: Int) -> String {
        String(format: "%064x", value)
    }
}
