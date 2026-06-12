/**
 * Aperture in-app dApp provider — injected into the MAIN FRAME of
 * every WKWebView page load by `BrowserWebView`. Exposes:
 *
 *   - `window.ethereum`  — EIP-1193 / EIP-6963 EVM provider
 *   - `window.solana`    — Phantom/Backpack-compatible Solana wallet
 *                          adapter surface
 *   - `window.aperture`  — Aperture-specific identity for dApps that
 *                          want to detect us explicitly
 *
 * Every dApp call (`request`, `signMessage`, `signTransaction`, …)
 * gets forwarded to native via the `aperture` `WKScriptMessageHandler`
 * with a crypto-random request id; native posts the result back by
 * calling the frozen `window.__apertureDispatch` function, which
 * resolves the matching promise from a closure-scoped pending map.
 *
 * **Hardening.**
 *   - `window.ethereum` / `window.solana` / `window.aperture` are
 *     defined non-writable + non-configurable so page scripts can't
 *     replace the provider with a malicious shim after injection.
 *   - The pending-request map and its resolver live inside this IIFE
 *     closure — no page-reachable handle can resolve or reject
 *     another script's in-flight requests.
 *   - `window.__apertureDispatch` is frozen, non-writable, and
 *     non-enumerable. Page scripts can call it, but request ids are
 *     128-bit values from `crypto.getRandomValues`, so forging a
 *     resolution for an id the page didn't create is infeasible.
 *   - `chainId` state is updated ONLY from native success responses —
 *     never from request params a page could fabricate.
 *
 * **Honesty (CLAUDE.md Rule #16).** The injected providers expose
 * exactly the standard surfaces — no telemetry, no third-party
 * fingerprinting, no remote logging. Source is inspectable inside the
 * app via the WKWebView Safari inspector (debug builds).
 */
(function () {
    "use strict";

    if (window.aperture && window.aperture.__installed__) {
        return; // Re-injection guard — `WKUserScript` reinjects on doc start.
    }

    // ----- request-id plumbing ---------------------------------------------------

    const pending = new Map(); // id (hex string) → { resolve, reject }

    function makeRequestId() {
        const bytes = new Uint8Array(16);
        window.crypto.getRandomValues(bytes);
        let out = "";
        for (let i = 0; i < bytes.length; i++) {
            const h = bytes[i].toString(16);
            out += h.length === 1 ? "0" + h : h;
        }
        return out;
    }

    function sendNativeRequest(channel, method, params) {
        return new Promise(function (resolve, reject) {
            const id = makeRequestId();
            pending.set(id, { resolve: resolve, reject: reject });
            try {
                window.webkit.messageHandlers.aperture.postMessage({
                    id: id,
                    channel: channel,
                    method: method,
                    params: params || []
                });
            } catch (err) {
                pending.delete(id);
                reject({ code: -32603, message: "Aperture bridge unavailable: " + err.message });
            }
        });
    }

    // Native posts the result back via the frozen
    // `window.__apertureDispatch({ id, result, error })`. The map and
    // this resolver stay closure-scoped; only the dispatch entry point
    // is exposed, and it can only resolve ids it is handed.
    function dispatchResponse(envelope) {
        if (!envelope || typeof envelope !== "object" || typeof envelope.id !== "string") {
            return;
        }
        const entry = pending.get(envelope.id);
        if (!entry) return;
        pending.delete(envelope.id);
        if (envelope.error) {
            entry.reject(envelope.error);
        } else {
            entry.resolve(typeof envelope.result === "undefined" ? null : envelope.result);
        }
    }

    // ----- EIP-1193 EthereumProvider ---------------------------------------------

    function EthereumProvider() {
        this.isAperture = true;
        this.isMetaMask = false;
        this.chainId = "0x1";       // overridden by native on `eth_chainId`
        this.networkVersion = "1";
        this.selectedAddress = null; // set when `eth_requestAccounts` resolves
        this._listeners = {};
    }

    EthereumProvider.prototype.request = function (args) {
        const self = this;
        if (!args || typeof args !== "object" || typeof args.method !== "string") {
            return Promise.reject({ code: -32600, message: "Invalid request" });
        }
        const method = args.method;
        const params = args.params || [];
        return sendNativeRequest("eth", method, params).then(function (result) {
            // Cache canonical state when relevant — ONLY from what
            // native confirmed, never from the request params.
            if (method === "eth_requestAccounts" || method === "eth_accounts") {
                if (Array.isArray(result) && result.length > 0) {
                    self.selectedAddress = result[0];
                    self._emit("accountsChanged", [result]);
                }
            } else if (method === "eth_chainId") {
                if (typeof result === "string" && result !== self.chainId) {
                    self.chainId = result;
                    self.networkVersion = String(parseInt(result, 16));
                    self._emit("chainChanged", [result]);
                }
            } else if (method === "wallet_switchEthereumChain") {
                // Native returns the CONFIRMED chain id hex on success.
                // Adopt that — not the requested params — then resolve
                // null to the dApp per EIP-3326.
                if (typeof result === "string" && result.indexOf("0x") === 0) {
                    if (result !== self.chainId) {
                        self.chainId = result;
                        self.networkVersion = String(parseInt(result, 16));
                        self._emit("chainChanged", [result]);
                    }
                }
                return null;
            }
            return result;
        });
    };

    // Legacy methods — most dApps still ship a fallback path that calls these.
    EthereumProvider.prototype.send = function (methodOrPayload, paramsOrCallback) {
        if (typeof methodOrPayload === "string") {
            return this.request({ method: methodOrPayload, params: paramsOrCallback || [] });
        }
        const cb = paramsOrCallback;
        const payload = methodOrPayload;
        if (typeof cb === "function") {
            this.sendAsync(payload, cb);
            return undefined;
        }
        return this.request({ method: payload.method, params: payload.params });
    };

    EthereumProvider.prototype.sendAsync = function (payload, callback) {
        const self = this;
        this.request({ method: payload.method, params: payload.params })
            .then(function (result) {
                callback(null, { id: payload.id, jsonrpc: "2.0", result: result });
            })
            .catch(function (err) {
                callback(err, null);
            });
    };

    EthereumProvider.prototype.enable = function () {
        return this.request({ method: "eth_requestAccounts" });
    };

    // Event emitter.
    EthereumProvider.prototype.on = function (event, handler) {
        if (!this._listeners[event]) this._listeners[event] = [];
        this._listeners[event].push(handler);
        return this;
    };
    EthereumProvider.prototype.removeListener = function (event, handler) {
        const arr = this._listeners[event];
        if (!arr) return this;
        const i = arr.indexOf(handler);
        if (i >= 0) arr.splice(i, 1);
        return this;
    };
    EthereumProvider.prototype.removeAllListeners = function (event) {
        if (event) {
            delete this._listeners[event];
        } else {
            this._listeners = {};
        }
        return this;
    };
    EthereumProvider.prototype._emit = function (event, args) {
        const arr = this._listeners[event];
        if (!arr) return;
        for (let i = 0; i < arr.length; i++) {
            try { arr[i].apply(null, args); } catch (e) { /* swallow */ }
        }
    };

    // ----- Solana wallet-adapter surface -----------------------------------------

    function SolanaProvider() {
        this.isAperture = true;
        this.isPhantom = false;
        this.publicKey = null;       // bs58 string when connected
        this._listeners = {};
    }

    SolanaProvider.prototype.connect = function (opts) {
        const self = this;
        const onlyIfTrusted = opts && opts.onlyIfTrusted === true;
        return sendNativeRequest("sol", "connect", [{ onlyIfTrusted: onlyIfTrusted }])
            .then(function (result) {
                if (result && result.publicKey) {
                    self.publicKey = { toString: function () { return result.publicKey; }, toBase58: function () { return result.publicKey; } };
                    self._emit("connect", [self.publicKey]);
                }
                return { publicKey: self.publicKey };
            });
    };

    SolanaProvider.prototype.disconnect = function () {
        const self = this;
        return sendNativeRequest("sol", "disconnect", []).then(function () {
            self.publicKey = null;
            self._emit("disconnect", []);
        });
    };

    SolanaProvider.prototype.signMessage = function (message, display) {
        // `message` arrives as Uint8Array from most dApps; serialize to hex.
        const hex = uint8ToHex(message);
        return sendNativeRequest("sol", "signMessage", [{ message: hex, display: display || "utf8" }])
            .then(function (result) {
                return {
                    signature: hexToUint8(result.signature),
                    publicKey: result.publicKey
                };
            });
    };

    SolanaProvider.prototype.signTransaction = function (transaction) {
        const hex = uint8ToHex(transaction.serialize({ requireAllSignatures: false, verifySignatures: false }));
        return sendNativeRequest("sol", "signTransaction", [{ transaction: hex }])
            .then(function (result) {
                // Reattach the native-signed bytes — dApps expect a Transaction.
                return result.signedTransaction; // hex; dApp recomposes via `Transaction.from`.
            });
    };

    SolanaProvider.prototype.signAndSendTransaction = function (transaction, opts) {
        const hex = uint8ToHex(transaction.serialize({ requireAllSignatures: false, verifySignatures: false }));
        return sendNativeRequest("sol", "signAndSendTransaction", [{ transaction: hex, options: opts || {} }])
            .then(function (result) {
                return { signature: result.signature };
            });
    };

    SolanaProvider.prototype.signAllTransactions = function (transactions) {
        const hexes = transactions.map(function (t) {
            return uint8ToHex(t.serialize({ requireAllSignatures: false, verifySignatures: false }));
        });
        return sendNativeRequest("sol", "signAllTransactions", [{ transactions: hexes }])
            .then(function (result) {
                return result.signedTransactions; // array of hex
            });
    };

    SolanaProvider.prototype.on = EthereumProvider.prototype.on;
    SolanaProvider.prototype.removeListener = EthereumProvider.prototype.removeListener;
    SolanaProvider.prototype.removeAllListeners = EthereumProvider.prototype.removeAllListeners;
    SolanaProvider.prototype._emit = EthereumProvider.prototype._emit;

    // ----- byte helpers ----------------------------------------------------------

    function uint8ToHex(bytes) {
        if (!bytes) return "0x";
        const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
        let out = "0x";
        for (let i = 0; i < arr.length; i++) {
            const h = arr[i].toString(16);
            out += h.length === 1 ? "0" + h : h;
        }
        return out;
    }
    function hexToUint8(hex) {
        if (!hex) return new Uint8Array(0);
        if (hex.indexOf("0x") === 0) hex = hex.slice(2);
        const out = new Uint8Array(hex.length / 2);
        for (let i = 0; i < out.length; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }

    // ----- EIP-6963: announce provider discovery --------------------------------
    // dApps that follow EIP-6963 listen for `eip6963:announceProvider` events
    // and won't fall back to `window.ethereum` until they hear one.

    function announceProvider(provider) {
        const info = {
            uuid: "f7a3c8b1-9d2e-4a6f-b8c0-aperture-provider",
            name: "Aperture",
            icon: "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMTAiIGZpbGw9IiMwQjBEMTEiLz48L3N2Zz4=",
            rdns: "com.thuglife.aperture"
        };
        const event = new CustomEvent("eip6963:announceProvider", {
            detail: Object.freeze({ info: info, provider: provider })
        });
        window.dispatchEvent(event);
    }

    // ----- install ---------------------------------------------------------------

    const ethProvider = new EthereumProvider();
    const solProvider = new SolanaProvider();

    function installProperty(name, value, enumerable) {
        try {
            Object.defineProperty(window, name, {
                value: value,
                writable: false,
                configurable: false,
                enumerable: enumerable !== false
            });
        } catch (e) {
            // A non-configurable property already exists (re-injection
            // edge). Keep the first installation — never overwrite.
        }
    }

    installProperty("ethereum", ethProvider);
    installProperty("solana", solProvider);
    installProperty("aperture", Object.freeze({
        __installed__: true,
        version: "1.0.0",
        ethereum: ethProvider,
        solana: solProvider
    }));
    installProperty("__apertureDispatch", Object.freeze(dispatchResponse), false);

    announceProvider(ethProvider);
    window.addEventListener("eip6963:requestProvider", function () {
        announceProvider(ethProvider);
    });
})();
