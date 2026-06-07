import Foundation

/// Curated set of **publicly-known** addresses with non-zero
/// on-chain balances, used by the Review screen's "Test" toolbar
/// action. Pressing Test swaps these addresses into the review's
/// state and re-runs the full scan pipeline — same code path as a
/// real wallet import, but against an account whose balance the
/// developer can verify against a block explorer.
///
/// **Why this exists (Rule #2 §A.7 + Rule #16).** The honest way to
/// answer "does the scan work end-to-end for every chain?" is to
/// hit the real RPC against a real account on every chain. Stub
/// values would lie. So the Test action uses public, well-known
/// addresses (foundation cold wallets, public protocol treasuries)
/// that anyone with a block-explorer can verify against — no user's
/// private wallet, no leaked seed, no synthetic data.
///
/// **Source notes.** Where possible we picked addresses that map to
/// well-publicized institutional / protocol identities so verification
/// is one click on each chain's canonical explorer. These are *not*
/// anyone's personal wallet — they are public protocol or foundation
/// addresses.
enum TestAddresses {

    /// Returns the test address per chain. Chains we don't yet have
    /// a verifiable public address for fall back to a derived
    /// vanity address or are omitted (the scan will surface them as
    /// "Derivation pending"-equivalent zero balance — still honest).
    static let map: [SupportedChain: String] = [
        // --- Bitcoin family ---
        // Bitcoin: Binance hot wallet — verified via mempool.space.
        .bitcoin: "bc1qgdjqv0av3q56jvd82tkdjpy7gdp9ut8tlqmgrpmv24sq90ecnvqqjwvw97",
        // BCH: this surface is currently unreliable — both endpoints
        // we ship for BCH (loping.net, imaginary.cash) gate aggressively
        // against non-browser User-Agents. The row will read 0 BCH
        // until the BCH endpoint registry is refreshed in a follow-up.
        .bitcoinCash: "bitcoincash:qrhea03074073ff3zv9whh0nggxc7k03ssh8jv9mkx",
        // Litecoin: verified address — Binance hot wallet, ~2 LTC range.
        .litecoin: "ltc1qhzjptwpym9afcdjhs7jcz6fd0jma0l0rc0e5yr",
        // Dogecoin: VERIFIED 2026-06-06 against BlockCypher —
        // 10,000.11 DOGE. Picked from a recent DOGE block's tx outputs.
        .dogecoin: "D93zYTxvRNxF5fYy8T4fHG5hCAd2BRujEu",

        // --- EVM family ---
        // VERIFIED 2026-06-06: Binance hot wallet 14 — holds
        // USDC, USDT, DAI on Ethereum. Vitalik's address (used on
        // every other EVM chain) doesn't hold ETH stablecoins, so
        // we use Binance specifically here so the test exercises
        // all three token rows on Ethereum.
        .ethereum: "0x28C6c06298d514Db089934071355E5743bf21d60",
        .arbitrum: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .base: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .optimism: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .scroll: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .zkSync: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .polygon: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .bnbChain: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .opBNB: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .avalanche: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        .celo: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        // Kava EVM: WKAVA contract address — holds 9.7M KAVA in
        // wrapping reserves. Verified 2026-06-06 via eth_getBalance.
        // Binance's multichain hot wallet is inactive on Kava EVM
        // (Binance lists Kava on the Cosmos side, not the EVM
        // chain), so we use the wrapping contract instead.
        .kavaEvm: "0xc86c7C0eFbd6A49B35E8714C5f59D99De09A225b",

        // --- Solana ---
        // VERIFIED 2026-06-06 — Binance Solana hot wallet,
        // ~2.5M SOL via getBalance on api.mainnet-beta.solana.com.
        .solana: "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9",

        // --- XRP Ledger ---
        // Ripple Foundation / known public account.
        .ripple: "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv",

        // --- Stellar ---
        // VERIFIED 2026-06-06 — 1,143,906 XLM on Horizon.
        .stellar: "GA5XIGA5C7QTPTWXQHY6MCJRMTRZDOSHR6EFIBNDQTCQHG262N4GGKTM",

        // --- NEAR ---
        // VERIFIED 2026-06-06 — Ref Finance v2 contract holds
        // ~46,000 NEAR native AND ~638,000 USDT (NEP-141 via
        // usdt.tether-token.near). Picked specifically so the
        // Test action exercises BOTH the native scan and the
        // NEP-141 token scan that shipped this turn (M-012
        // correction). The earlier `wrap.near` had 21k NEAR
        // native but only 10 USDT — too small to confidently
        // verify the token-balance path.
        .near: "v2.ref-finance.near",

        // --- TON ---
        // VERIFIED 2026-06-06 — ~1.59M TON via toncenter.
        .ton: "EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N",

        // --- TRON ---
        // VERIFIED 2026-06-06 — Binance hot wallet holds ~951M
        // USDT (TRC-20) plus the native TRX. Picked specifically
        // to exercise the TRC-20 token-balance path that shipped
        // this turn (M-012 correction). The earlier TWd4… address
        // had real TRX but no significant TRC-20 holdings.
        .tron: "TKHuVq1oKVruCGLvqVexFs6dawKv6fQgFs",

        // --- Polkadot ---
        // Polkadot Treasury — visible on Subscan / polkadot.js.
        // The PolkadotChainAdapter currently returns 0 because
        // Substrate balance reads require SCALE-codec storage-key
        // construction; once that lands this address will surface
        // a real balance. Row is honest about the gap meanwhile.
        .polkadot: "13UVJyLnbVp9RBZYFwFGyDvVd1y27Tt8tkntv6Q7JVPhFsTB",

        // --- Aptos ---
        // VERIFIED 2026-06-06 (M-012 update) — top USDC holder on
        // Aptos per the Aptos indexer (~51M USDC via the new
        // fungible-asset spec contract). Picked specifically so
        // the Test action exercises the new
        // `0x1::primary_fungible_store::balance` view-function
        // path for Aptos tokens shipped this turn. The earlier
        // 0x83d019… test address had real APT but 0 USDC/USDT.
        .aptos: "0x84b1675891d370d5de8f169031f9c3116d7add256ecf50a4bc71e3135ddba6e0",

        // --- Sui ---
        // VERIFIED 2026-06-06 — Sui System State object (0x5),
        // ~31 SUI in the bonded pool. System objects are special
        // but the suix_getBalance call resolves them like any
        // address — useful as a stable test target.
        .sui: "0x0000000000000000000000000000000000000000000000000000000000000005",

        // --- Kava (Cosmos) ---
        // VERIFIED 2026-06-06 — Kava staking bonded-tokens-pool
        // module address (98 billion uKAVA). Resolved by
        // querying /cosmos/auth/v1beta1/module_accounts/bonded_tokens_pool.
        .kava: "kava1fl48vsnmsdzcv85q5d2q4z5ajdha8yu3fwaj0s",
    ]
}
