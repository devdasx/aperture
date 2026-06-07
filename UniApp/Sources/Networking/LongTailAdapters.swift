import Foundation

/// Long-tail chain adapters consolidated into one file. Each is a
/// small Sendable struct with `fetchAccountSummary(address)` →
/// `(balance, isUsed)`. Decoding pattern: every adapter calls
/// `client.callJSONResultData(...)` to get `Data`, then decodes via
/// `JSONSerialization.jsonObject` — the Data shuttle is the
/// Swift-6-strict-concurrency boundary across the actor.

struct ChainAccountSummary: Sendable {
    let nativeBalance: Decimal
    let isUsed: Bool
}

// MARK: - XRP (Ripple)

struct XRPChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callJSONResultData(
                chain: .ripple,
                method: "account_info",
                params: [["account": address, "ledger_index": "validated"]]
            )
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let info = dict["account_data"] as? [String: Any],
               let balanceStr = info["Balance"] as? String,
               let drops = Decimal(string: balanceStr) {
                let xrp = drops / 1_000_000
                return ChainAccountSummary(nativeBalance: xrp, isUsed: xrp > 0)
            }
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - Stellar

struct StellarChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(chain: .stellar, path: "accounts/\(address)")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let balances = json["balances"] as? [[String: Any]] else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let nativeStr = balances.first(where: { $0["asset_type"] as? String == "native" })?["balance"] as? String ?? "0"
            let balance = Decimal(string: nativeStr) ?? 0
            return ChainAccountSummary(nativeBalance: balance, isUsed: balance > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - NEAR

struct NEARChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        // NEAR's `query` method requires named-object params, NOT a
        // positional array. The shared `callJSONResultData` path
        // produced 0-balance responses on device even though the
        // body was byte-identical to a working curl — likely a
        // `[String: Sendable] → [String: Any]` bridging quirk in
        // Swift 6 that doesn't surface in tooling. To stay reliable
        // we POST directly via URLSession and parse the JSON
        // response shape ourselves. No rate-limit / circuit-breaker
        // — NEAR's `query` is read-only and the official endpoint
        // doesn't throttle here.
        let urlString = "https://rpc.mainnet.near.org"
        guard let url = URL(string: urlString) else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        // Hand-build the body so the `params` field is a JSON object
        // (not an array). Use raw string concatenation rather than
        // `[String: Any]` round-tripping through JSONSerialization to
        // sidestep the bridging issue.
        let escapedAddress = address.replacingOccurrences(of: "\"", with: "\\\"")
        let bodyString = """
        {"jsonrpc":"2.0","id":1,"method":"query","params":{"request_type":"view_account","finality":"final","account_id":"\(escapedAddress)"}}
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let amountStr = result["amount"] as? String,
                  let yocto = Decimal(string: amountStr) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let near = yocto / Self.yoctoPerNear
            return ChainAccountSummary(nativeBalance: near, isUsed: near > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }

    private static let yoctoPerNear: Decimal = {
        var n = Decimal(1)
        for _ in 0..<24 { n *= 10 }
        return n
    }()
}

// MARK: - TON

struct TONChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(
                chain: .ton, path: "getAddressBalance",
                query: [URLQueryItem(name: "address", value: address)]
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultStr = json["result"] as? String,
                  let nano = Decimal(string: resultStr) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let ton = nano / 1_000_000_000
            return ChainAccountSummary(nativeBalance: ton, isUsed: ton > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - TRON

struct TRONChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(chain: .tron, path: "v1/accounts/\(address)")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]],
                  let first = arr.first else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            // TRON's `balance` is an unsigned int in SUN. Defensive:
            // JSONSerialization may return it as `NSNumber` OR `Int`
            // OR (for very large values) `NSDecimalNumber`. Try each
            // shape rather than assume a single cast.
            let sun: Decimal
            if let n = first["balance"] as? NSDecimalNumber {
                sun = n.decimalValue
            } else if let n = first["balance"] as? NSNumber {
                sun = NSDecimalNumber(value: n.int64Value).decimalValue
            } else if let i = first["balance"] as? Int {
                sun = Decimal(i)
            } else if let s = first["balance"] as? String,
                      let dec = Decimal(string: s) {
                sun = dec
            } else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let trx = sun / 1_000_000
            return ChainAccountSummary(nativeBalance: trx, isUsed: trx > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - Polkadot

/// Polkadot balance via direct `state_getStorage` against the
/// `System::Account` storage map.
///
/// **Storage key construction (Substrate convention):**
///   `twox128("System") ‖ twox128("Account") ‖ blake2_128(accountId) ‖ accountId`
///
/// **Response decoding (AccountInfo SCALE):**
///   `nonce: u32` (4 bytes LE)
///   `consumers: u32` (4)
///   `providers: u32` (4)
///   `sufficients: u32` (4)
///   `data: AccountData {`
///     `free: u128` (16 bytes LE) ← what we read
///     `reserved: u128` (16)
///     `frozen: u128` (16)
///     `flags: u128` (16)
///   `}`
///
/// First 16 bytes of `data` (offset 16) are the **free** balance.
/// Plancks: divide by 10^10 to get DOT.
///
/// **Why direct URLSession.** Same reason as NEAR adapter — the
/// shared abstraction's `[String: Sendable]` plumbing had a
/// bridging quirk; for one-off RPC paths the direct URLSession
/// approach is more reliable than chasing the abstraction.
/// Per-endpoint rate limit isn't needed for a single read per
/// scan pass.
struct PolkadotChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        // 1. SS58 decode → AccountId32.
        guard let accountId = SS58.decodeAccountId(address) else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 2. Storage key.
        var key: [UInt8] = []
        key.append(contentsOf: Twox.twox128(Array("System".utf8)))
        key.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        key.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        key.append(contentsOf: accountId)
        let keyHex = "0x" + key.map { String(format: "%02x", $0) }.joined()

        // 3. POST state_getStorage directly via URLSession.
        guard let url = URL(string: "https://rpc.polkadot.io") else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let bodyString = """
        {"jsonrpc":"2.0","id":1,"method":"state_getStorage","params":["\(keyHex)"]}
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            data = responseData
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 4. Parse JSON, expect result to be a hex string "0x…" or null.
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        guard let resultStr = root["result"] as? String,
              resultStr.hasPrefix("0x") else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let hex = String(resultStr.dropFirst(2))
        guard let bytes = Self.hexBytes(hex), bytes.count >= 32 else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 5. Decode `data.free` u128 at offset 16 (skip 4×u32 = 16
        //    bytes of AccountInfo header).
        let freeBytes = Array(bytes[16..<32])
        let freePlanck = Self.decodeU128LE(freeBytes)
        let dot = freePlanck / Self.planckPerDot
        return ChainAccountSummary(nativeBalance: dot, isUsed: dot > 0)
    }

    private static let planckPerDot: Decimal = {
        var n = Decimal(1)
        for _ in 0..<10 { n *= 10 }
        return n
    }()

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            result.append(b)
            i = next
        }
        return result
    }

    private static func decodeU128LE(_ bytes: [UInt8]) -> Decimal {
        var n = Decimal(0)
        var place = Decimal(1)
        let b256 = Decimal(256)
        for byte in bytes {
            n += Decimal(Int(byte)) * place
            place *= b256
        }
        return n
    }
}

// MARK: - Aptos

struct AptosChainAdapter: Sendable {
    let client: RPCClient

    /// Aptos balance via the `0x1::coin::balance` view function —
    /// works against BOTH the legacy `CoinStore` resource AND the
    /// new fungible-asset (FA) model Aptos migrated to in 2024.
    /// The previous direct `resource/CoinStore` path returned
    /// `resource_not_found` for any account that's already on the
    /// FA model (every recently-active account), so the view-function
    /// path is the canonical one.
    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let body: [String: Sendable] = [
                "function": "0x1::coin::balance",
                "type_arguments": ["0x1::aptos_coin::AptosCoin"],
                "arguments": [address],
            ]
            let data = try await client.callRESTPost(
                chain: .aptos,
                path: "view",
                body: body
            )
            // Returns a JSON array with one string element (the
            // balance in octas, 10^8 per APT).
            guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  let valueStr = arr.first as? String,
                  let octas = Decimal(string: valueStr) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let apt = octas / 100_000_000
            return ChainAccountSummary(nativeBalance: apt, isUsed: apt > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - Sui

struct SuiChainAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callJSONResultData(
                chain: .sui, method: "suix_getBalance", params: [address]
            )
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let totalStr = dict["totalBalance"] as? String,
                  let mist = Decimal(string: totalStr) else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let sui = mist / 1_000_000_000
            return ChainAccountSummary(nativeBalance: sui, isUsed: sui > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}

// MARK: - Kava (Cosmos)

struct CosmosKavaAdapter: Sendable {
    let client: RPCClient

    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(
                chain: .kava,
                path: "cosmos/bank/v1beta1/balances/\(address)"
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let balances = json["balances"] as? [[String: Any]] else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let native = balances.first(where: { $0["denom"] as? String == "ukava" })
            let amountStr = native?["amount"] as? String ?? "0"
            let ukava = Decimal(string: amountStr) ?? 0
            let kava = ukava / 1_000_000
            return ChainAccountSummary(nativeBalance: kava, isUsed: kava > 0)
        } catch {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }
}
