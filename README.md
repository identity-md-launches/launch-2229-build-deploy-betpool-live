# BetPool

BetPool is a non-upgradeable, signed, weighted pari-mutuel betting contract for NIGHTSHIFT's NIGHT CHESS, Space Pinball, and Agent Arena. It accepts the two specified ERC-20s, aggregates each wallet's stakes on both sides, pays the fixed fee splitter at settlement, and lets bettors pull their payouts.

The deployable application is **`src/BetPool.sol:BetPool`**. It has **no constructor arguments** and makes no external calls during construction. This repository supplies the application, offline dependencies, tests, and launch handoff. The IdentityMD deployment service performs the Ethereum launch after acceptance; no transaction has been broadcast from this project, and no deployment address is asserted here.

## Build and check

The project uses Solidity **0.8.26**, optimizer 200 runs, the IR pipeline, Paris EVM output, and `bytecode_hash = "none"`. Dependencies are ordinary vendored files under `lib/`; neither package downloads nor submodules are needed for verification. The pinned compiler must be installed in the verification environment.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xc0d572c491c9498cbd951bff91d7247db3e26d15e9ee6d98197d3e70cde73821 forge test
forge fmt --check
```

Tests use local mocks at the specified token addresses, test-only signing keys, independent EIP-712 hashing, and no RPC, environment reads, FFI, or filesystem permissions. Test keys are fixtures, never launch configuration. See [test coverage and review](docs/REVIEW.md) and [dependency provenance](docs/DEPENDENCIES.md).

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Launch chain | Ethereum, chain ID 1 |
| Permanent owner | `0x6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5` |
| IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| SHIFT | `0xe5e58e53d0bb204aa62c995a6c8cc8a48e60c3ac` |
| Fee splitter | `0x1119d5df2f046bc2d3c0f6279ef2e9ce49422d44` |
| Fee | 500 bps, taken only from losing-side stakes |
| IMD initial bet limits | 0.1–500 IMD, inclusive |
| SHIFT initial bet limits | 1,000–25,000,000 SHIFT, inclusive |
| IMD immutable maximum | 10,000 IMD per bet |
| SHIFT immutable maximum | 500,000,000 SHIFT per bet |
| Signed weight | 500–10,000 bps, inclusive |
| Market creation horizon | Strictly future through 7 days ahead |
| Ticket expiry horizon | Current timestamp through 120 seconds ahead |
| Unsettled-market refund delay | 24 hours after `closesAt` |
| Domain | `NightshiftBets`, version `1`, current chain ID, deployed contract address |

Both tokens are treated as plain, non-rebasing ERC-20s with 18 decimals and no transfer fees, as specified. All on-chain amounts and limit arguments are **base units**, not whole tokens. For example, 1,000 SHIFT is `1000000000000000000000` units. Supported token addresses, fee recipient, fee, caps, and owner are constants. Factories and deployers acquire no authority.

## After launch

The actual NIGHTSHIFT result-signing address is not supplied in the brief. It is intentionally **unconfigured** at construction. There is no guessed signer and no constructor dependency on GameEscrow.

1. The named owner obtains the actual backend EOA result signer from the NIGHTSHIFT operator, confirming it against the operator's GameEscrow deployment at `0xf460fd9ad76f18414f54a2431870e8a116193489` on the launch chain. Do not use the escrow contract's own address as the signing key address.
2. The owner calls **`setSigner(actualSigner)`** and confirms `SignerSet` and `signer()`. Zero is rejected. Before this configuration, signed actions fail with `SignerNotConfigured`; the unset value is a disabled state, never an authorized identity. This is the only required operational setting, using the setter explicitly permitted by the brief.
3. The operator configures the signing backend and spectator application with the confirmed BetPool deployment address and chain ID. Publish the confirmed address and verified source through the launch handoff.
4. The owner may call `setLimits(token,min,max)` if different per-bet bounds are desired. Defaults are already initialized in the constructor, and no setting can exceed the fixed caps.

No initialization transaction by the deployment factory is required. Signer activation is a subsequent owner operation before the service opens. The manifest step owns `launch.json`; this project intentionally does not supply that file.

## Lifecycle and payouts

`createMarket(marketId,token,closesAt,game,sig)` is permissionless with a valid signed Market message. IDs are globally unique for the lifetime of this deployment. `game` is an opaque `bytes32` identifier selected and signed by the backend; no hard-coded game allowlist or encoding convention is imposed.

Spectators first approve the market's token, then call `bet(...)` themselves. The signature binds `bettor = msg.sender`, so another wallet cannot relay or steal a ticket. The contract enforces the current per-token limits, side 0 or 1, the weight range, an unused global nonce, an open market, and an inclusive ticket expiry no more than 120 seconds away at inclusion. `block.timestamp == closesAt` is already closed. Actual token receipt must equal the stake exactly.

Each ticket adds `floor(amount * weightBps / 10000)` shares to that wallet and side. Repeated bets add their individually rounded shares; weights are not averaged. A wallet can bet on both sides. The signed weight is chosen by NIGHTSHIFT, not calculated from game state by the contract.

Anyone can relay `settle(marketId,outcome,deadline,sig)`. Outcomes are A = 0, B = 1, void = 2. The deadline is inclusive and has no maximum lifetime. A signed settlement can occur before the scheduled close and immediately ends betting. No result can be replaced after settlement or expiry.

For a normal two-sided market, let `L` be total losing stakes and `S` the winning side's total shares:

```text
fee = floor(L * 5 / 100)
bonusPool = L - fee
walletPayout = walletWinningStake + floor(bonusPool * walletWinningShares / S)
```

The fee is transferred at settlement to the fixed splitter. The bonus rounds down once per winning wallet, using full-precision multiplication/division. Total rounding dust is less than one token wei per winning wallet, or less than the number of winning wallets in aggregate. Claims consume a separate per-market ledger, so other markets' funds cannot cover a claim. Direct token donations do not increase shares or payouts. Dust and accidental donations remain locked permanently; there is no sweep function.

Void markets and markets with either side empty refund every wallet's exact combined stakes, with zero fee. At or after `closesAt + 24 hours`, anyone can `expire` an unsettled market and produce the same refunds. Expiry records outcome 2 and emits `Expired`. A valid signed settlement remains possible after that time until someone expires the market; the first successful finalization wins.

`claim` pays only the caller and marks the wallet claimed once. Losing-only wallets and nonparticipants receive zero; their zero-value claim succeeds and emits `Claimed(...,0)`. `claimable` is zero before settlement, after a claim, for unknown markets, or for a losing-only wallet. `claimMany` is an atomic list of claims, can mix tokens, and accepts an empty list. An unknown, unsettled, already-claimed, or duplicate market reverts the whole batch. Split long lists to fit the block gas limit.

### Minimum-share edge case

The owner may set a minimum as low as one token wei, as long as `0 < min <= max <= cap`. Such tiny stakes can round to zero shares at a low weight. **A ticket whose computed shares are zero reverts with `ZeroShares`.** This explicit safety assumption prevents a nonempty winning side with no defined pro-rata denominator; it does not change the required share formula. A minimum of 20 base units ensures every permitted weight produces at least one share. The supplied initial limits are far above this threshold. The backend must check this condition if the owner reduces limits to dust-sized amounts.

## Signatures and integration

Canonical field names, types and order are in [eip712-types.json](docs/eip712-types.json). Use `eth_signTypedData_v4` semantics with these primary types:

```text
Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)
Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)
Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)
```

Signatures are 65-byte `r || s || v` ECDSA signatures, with low `s` and `v` equal to 27 or 28. Personal-sign wrapping, compact 64-byte signatures, and ERC-1271 contract validation are not used. The domain is tied to this contract and the current chain, including after a chain-ID change. `DOMAIN_SEPARATOR()` and `eip712Domain()` expose it.

Ticket nonces are **global**, across wallets, markets, tokens, and signer rotations. Allocate a unique `bytes32` for each ticket; consumption is permanent only after a successful bet. Failed bets roll back nonce use. Market IDs prevent Market replay; finalization prevents Outcome replay. Market and Outcome signatures cannot substitute for Ticket signatures.

The ABI exposes the required `markets`, `betsOf`, `claimable`, `limits`, `usedNonce`, `signer`, and `paused` views. `marketBalance` additionally exposes each market's unpaid pot including its dust. Events are `MarketCreated`, `BetPlaced`, `Settled`, `Claimed`, `Expired`, `SignerSet`, `LimitsSet`, and inherited `Paused`/`Unpaused`. Initial limits emit `LimitsSet` in the constructor.

## Operational responsibilities and trust

The NIGHTSHIFT operator authenticates bettors, evaluates match state and underdog/early weights, issues short-lived tickets and unique IDs/nonces, stops ticket issuance when results are known, and signs exactly one correct outcome per market. The on-chain contract verifies authorization; it does not verify gameplay or the accuracy of a result. Avoid long-lived outcome authorizations and never issue conflicting outcomes. A valid ticket expiring within 120 seconds at inclusion does not itself prove when it was originally issued.

The permanent owner can rotate the signer, adjust bounded limits, and pause/unpause new markets and bets. The signer can determine every market's result and economic weights, and the owner can appoint that signer; these are material trust assumptions. Rotating the signer immediately invalidates unused signatures from prior keys, including pending outcomes for existing markets. The new signer must reissue needed authorizations. Reappointing an old key can make its still-valid, unused signatures valid again; consumed nonces remain used.

Pausing never stops settlement, expiry or claims and never extends any deadline. If the signer disappears, expiry provides a permissionless refund path. If fee transfer fails, settlement reverts completely and expiry remains possible. If a payout transfer fails, the claim remains unconsumed. Token-level transfer restrictions can still prevent payments until the token permits them; BetPool cannot override token behavior.

There is no ownership transfer/renunciation, emergency withdrawal, arbitrary execution, approval of user funds to others, fee update, recipient update, token addition, upgrade path, delegatecall or selfdestruct. Loss of the owner's key prevents configuration changes but does not block existing authorized settlements, expiry or claims. An independent adversarial review is still required before accepting live funds; the included checks are local verification, not an external audit.
