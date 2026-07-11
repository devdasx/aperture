import Foundation

struct TronChainAdapter: Sendable {
    let client: RPCClient

    func fetchTokenMetadata(contract: String) async throws(RPCError) -> TokenMetadataFetchResult {
        async let nameHexTask: String? = try? await callTRC20View(contract: contract, functionSelector: "name()")
        async let symbolHexTask: String? = try? await callTRC20View(contract: contract, functionSelector: "symbol()")
        async let decimalsHexTask: String? = try? await callTRC20View(contract: contract, functionSelector: "decimals()")

        let nameHex = await nameHexTask ?? ""
        let symbolHex = await symbolHexTask ?? ""
        let decimalsHex = await decimalsHexTask ?? ""

        let name = EVMChainAdapter.decodeABIString(hex: nameHex)
        let symbol = EVMChainAdapter.decodeABIString(hex: symbolHex)
        let decimals = EVMChainAdapter.decodeUInt8(hex: decimalsHex)

        if !name.isEmpty || !symbol.isEmpty {
            return TokenMetadataFetchResult(
                name: name.isEmpty ? symbol : name,
                symbol: symbol.isEmpty ? name : symbol,
                decimals: decimals
            )
        }

        if let registry = TronTokenRegistry.tokens.first(where: { $0.contract == contract }) {
            return TokenMetadataFetchResult(
                name: registry.name,
                symbol: registry.symbol,
                decimals: registry.decimals
            )
        }

        throw .decodingFailed("Contract did not return TRC-20 name/symbol")
    }

    private func callTRC20View(
        contract: String,
        functionSelector: String
    ) async throws(RPCError) -> String {
        let data = try await client.callRESTPost(
            chain: .tron,
            path: "wallet/triggerconstantcontract",
            body: [
                "owner_address": TronAddressCodec.nullAddress,
                "contract_address": contract,
                "function_selector": functionSelector,
                "parameter": "",
                "visible": true,
            ]
        )
        let response: TronTriggerConstantResponse
        do {
            response = try JSONDecoder().decode(TronTriggerConstantResponse.self, from: data)
        } catch {
            throw .decodingFailed("Could not decode TRON constant call response: \(error.localizedDescription)")
        }
        if let ok = response.result?.result, !ok {
            throw .decodingFailed(response.result?.message ?? "TRON constant call failed")
        }
        guard let hex = response.constantResult?.first, !hex.isEmpty else {
            throw .decodingFailed("TRON constant call returned no result")
        }
        return hex
    }
}

private struct TronTriggerConstantResponse: Decodable {
    let result: TronTriggerConstantResult?
    let constantResult: [String]?

    enum CodingKeys: String, CodingKey {
        case result
        case constantResult = "constant_result"
    }
}

private struct TronTriggerConstantResult: Decodable {
    let result: Bool?
    let message: String?
}
