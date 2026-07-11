import Foundation
import Testing
import WalletCore
@testable import Aperture

/// BUG-016: Bitcoin-family receive/change gap-20 address book + change allocation.
@Suite("Bitcoin-family address book (BUG-016)")
struct BitcoinFamilyAddressBookTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test("Gap limit is 20 for every Bitcoin-family chain")
    func gapLimitIs20() {
        #expect(BitcoinFamilyAddressBook.gapLimit == 20)
        for chain in [SupportedChain.bitcoin, .bitcoinCash, .litecoin, .dogecoin] {
            #expect(BitcoinFamilyAddressBook.isBitcoinFamily(chain))
            #expect(BitcoinFamilyAddressBook.primaryPurpose(for: chain) == 84
                || BitcoinFamilyAddressBook.primaryPurpose(for: chain) == 44)
        }
    }

    @Test("Path format is m/purpose'/coin'/0'/branch/index for all chains")
    func pathFormat() {
        #expect(
            BitcoinFamilyAddressBook.path(purpose: 84, chain: .bitcoin, branch: 0, index: 0)
                == "m/84'/0'/0'/0/0"
        )
        #expect(
            BitcoinFamilyAddressBook.path(purpose: 84, chain: .bitcoin, branch: 1, index: 3)
                == "m/84'/0'/0'/1/3"
        )
        #expect(
            BitcoinFamilyAddressBook.path(purpose: 44, chain: .bitcoinCash, branch: 1, index: 0)
                == "m/44'/145'/0'/1/0"
        )
        #expect(
            BitcoinFamilyAddressBook.path(purpose: 84, chain: .litecoin, branch: 0, index: 1)
                == "m/84'/2'/0'/0/1"
        )
        #expect(
            BitcoinFamilyAddressBook.path(purpose: 44, chain: .dogecoin, branch: 1, index: 5)
                == "m/44'/3'/0'/1/5"
        )
    }

    @Test("Derive receive and change addresses with WalletCore for BTC BIP84")
    func deriveBTCReceiveAndChange() throws {
        let words = Self.mnemonic.split(separator: " ").map(String.init)
        let receive = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoin, purpose: 84, branch: 0, index: 0
        )
        let change = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoin, purpose: 84, branch: 1, index: 0
        )
        #expect(receive.address.hasPrefix("bc1q"))
        #expect(change.address.hasPrefix("bc1q"))
        #expect(receive.address != change.address)
        #expect(receive.path == "m/84'/0'/0'/0/0")
        #expect(change.path == "m/84'/0'/0'/1/0")
        #expect(AnyAddress.isValid(string: receive.address, coin: .bitcoin))
        #expect(AnyAddress.isValid(string: change.address, coin: .bitcoin))
    }

    @Test("Derive BCH BIP44 change path is distinct from receive")
    func deriveBCHChange() throws {
        let words = Self.mnemonic.split(separator: " ").map(String.init)
        let receive = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoinCash, purpose: 44, branch: 0, index: 0
        )
        let change = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoinCash, purpose: 44, branch: 1, index: 0
        )
        #expect(receive.address != change.address)
        #expect(change.path.contains("/1/0"))
        #expect(AnyAddress.isValid(string: receive.address, coin: .bitcoinCash))
        #expect(AnyAddress.isValid(string: change.address, coin: .bitcoinCash))
    }

    @Test("Persist + allocateChangeAddress yields next unused …/1/i path")
    func persistAndAllocateChange() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let words = Self.mnemonic.split(separator: " ").map(String.init)
        let walletId = UUID()
        try awaitInsertWallet(walletId: walletId, database: database)

        let seed = try BitcoinFamilyAddressBook.deriveGapWindow(
            words: words,
            chain: .bitcoin,
            startIndex: 0,
            count: BitcoinFamilyAddressBook.gapLimit,
            purposes: [84]
        )
        try BitcoinFamilyAddressBook.persist(
            walletId: walletId,
            chain: .bitcoin,
            addresses: seed,
            database: database
        )

        // Mark change/0 as used so allocation advances to change/1.
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE wallet_addresses SET is_used = 1
                WHERE wallet_id = ? AND chain_raw = ? AND derivation_path = ?
                """,
                arguments: [
                    walletId.uuidString,
                    SupportedChain.bitcoin.rawValue,
                    "m/84'/0'/0'/1/0"
                ]
            )
        }

        let change = try #require(
            try BitcoinFamilyAddressBook.allocateChangeAddress(
                walletId: walletId,
                chain: .bitcoin,
                words: words,
                database: database
            )
        )
        let expected = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoin, purpose: 84, branch: 1, index: 1
        )
        #expect(change == expected.address)
        #expect(change != expected.path) // address, not path
        // Must not be the receive primary address.
        let receive0 = try BitcoinFamilyAddressBook.deriveAddress(
            words: words, chain: .bitcoin, purpose: 84, branch: 0, index: 0
        )
        #expect(change != receive0.address)
    }

    @Test("ensureGapCoverage extends when highest used sits at end of window")
    func ensureGapExtendsAfterUsedTail() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let words = Self.mnemonic.split(separator: " ").map(String.init)
        let walletId = UUID()
        try awaitInsertWallet(walletId: walletId, database: database)

        // Seed indices 0…19 for BIP84 only.
        let seed = try BitcoinFamilyAddressBook.deriveGapWindow(
            words: words,
            chain: .bitcoin,
            startIndex: 0,
            count: 20,
            purposes: [84]
        )
        try BitcoinFamilyAddressBook.persist(
            walletId: walletId,
            chain: .bitcoin,
            addresses: seed,
            markUsed: [seed.first { $0.branch == 0 && $0.index == 19 }!.address],
            database: database
        )

        let extended = try BitcoinFamilyAddressBook.ensureGapCoverage(
            walletId: walletId,
            chain: .bitcoin,
            words: words,
            database: database
        )
        #expect(!extended.isEmpty)
        let high = try #require(
            try BitcoinFamilyAddressBook.highestPersistedIndex(
                walletId: walletId,
                chain: .bitcoin,
                purpose: 84,
                branch: 0,
                database: database
            )
        )
        // highest used 19 → need through 19+20 = 39
        #expect(high >= 39)
    }

    @Test("Gap window derives exactly gapLimit receive and change per purpose")
    func gapWindowCounts() throws {
        let words = Self.mnemonic.split(separator: " ").map(String.init)
        let window = try BitcoinFamilyAddressBook.deriveGapWindow(
            words: words,
            chain: .dogecoin,
            startIndex: 0,
            count: 20,
            purposes: [44]
        )
        #expect(window.count == 40) // 20 receive + 20 change
        #expect(window.filter { $0.branch == 0 }.count == 20)
        #expect(window.filter { $0.branch == 1 }.count == 20)
        #expect(Set(window.map(\.address)).count == 40)
    }

    // MARK: - Helpers

    private func awaitInsertWallet(walletId: UUID, database: AppDatabase) throws {
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'BTC Test', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'bitcoin', 'bc1qseed', ?, 0, 1)
                """,
                arguments: [UUID().uuidString, walletId.uuidString, "m/84'/0'/0'/0/0"]
            )
        }
    }
}
