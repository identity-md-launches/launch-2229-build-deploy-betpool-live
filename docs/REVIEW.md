# Verification and review notes

This is a local implementation review, not an independent audit or a claim of production deployment. It uses the supplied protected deployment definitions and pinned security reference as task inputs. The application is only `BetPool`; helpers, token mocks and handlers under `test/` are never launch contracts.

## Test coverage

| Suite | Main evidence |
| --- | --- |
| `BetPoolFlows.t.sol` | Both tokens and winners, stakes at and between limits, repeated and dual-side bets, weighted payouts, odd losing amounts, exact fees, dust, void and empty/one-sided refunds, expiry boundary, mixed-token batches, rollback of bad batches, independent market pots, donations |
| `BetPoolSignatures.t.sol` | Independent domain/type hashing, each signed field mutated, wrong key/contract/chain, chain-ID change, malformed/high-s/bad-v/personal-sign signatures, nonce replay across wallets/markets/rotations, exact time boundaries, replayed market IDs/outcomes, owner cannot bypass signer |
| `BetPoolSafety.t.sol` | Raw CREATE2 construction without token/splitter code, correct fixed owner, bounded runtime and opcode scan, access control, fixed recipients/caps, changed limits, pause behavior, failure rollback, exact transfer receipt, SafeERC20 no-return support, token callbacks and reentrancy guard, settlement window boundaries (decisive only from `closesAt`, nothing from `closesAt + 24 h`, void any time), the held-ticket race, and the expiry/settle non-race |
| `BetPoolEvents.t.sol` | Market, bet, settlement, zero/nonzero claim, signer, limits, pause, unpause and expiry events |
| `BetPoolFuzz.t.sol` | Eight bettors, both sides, repeated weights, both tokens, all outcomes, forward/reverse claim order, exact reference payouts, full conservation, refund completeness, dust bound, amounts up to both hard caps |
| `BetPoolInvariant.t.sol` | Independent state/accounting model over up to 24 markets and six bettors; deposits, settlements, expiry, claims/batches, clock advances, limits, signer rotations, pauses, donations; all remaining entitlements drained at campaign end |

The configured fuzz tests use 512 cases each. Stateful tests use 128 runs at depth 96 with `fail_on_revert = true`. All three invariant properties are checked together in each randomized sequence. Campaigns begin with stakes in both tokens and on both sides; actions skip inapplicable states, but an unexpected revert fails the test. The finish step expires remaining markets and claims every wallet, checking that refunds leave no funds and normal markets leave only the permitted dust.

The invariant model independently maintains token deposits, fees, payouts, donations, per-market amounts/shares, per-wallet positions, and claimed flags. It checks:

- Actual pool balances equal the sum of market ledgers plus donations.
- Pool balance + all payouts + fees equals all deposits + donations, separately for each token.
- Every `claimable` value matches the independently computed entitlement.
- Unpaid entitlements never exceed the corresponding market's balance.
- No market's cumulative payouts plus fee exceed its deposits.
- Splitter and bettor token balances equal modeled receipts.
- Token identities, owner, fee recipient and fee rate remain fixed; consumed nonces stay consumed.

Tests do not depend on environment variables, RPC calls, external services or transaction ordering. They read simulated time through `vm.getBlockTimestamp()` so the Solidity optimizer cannot reuse a timestamp across a test-only `vm.warp` mutation. Signature-domain changes use explicit expected chain IDs.

## Arithmetic and custody review

For a normal market, all accepted stakes have positive integer shares. Wallet shares sum exactly to side shares. Thus for bonus pool `R` and winning wallet shares `s_i`, `sum(floor(R*s_i/S)) <= R`, with less than one unit lost per winning wallet. Winning principal is returned exactly. The fee is `floor(L/20)`, exactly `floor(5*L/100)` without overflowing a multiplication. The remaining bonus is `L - fee`, not independently rounded `floor(0.95*L)`.

The payout uses OpenZeppelin's full-precision `Math.mulDiv`. Per-bet hard caps keep `amount * weightBps` below the uint256 limit. Market and wallet accumulation use checked arithmetic. A separate market balance is increased only by accepted stakes, decreased before fee/payout transfers, and checked by subtraction on every payment. Aggregate token balances and unsolicited donations never determine an entitlement.

Every mutating entry point uses the same reentrancy guard. Checks and entitlement changes precede token transfers. ERC-20 receipt is measured before/after `transferFrom` and must match exactly. False-returning, reverting, missing-code and inexact pull behavior is exercised; failed calls leave the nonce, position, allowance and market ledger unchanged. Tests also exercise failed fee transfers and failed claims. A failed claim retains its entitlement, and settlement failure leaves the timeout refund path available.

The two specified tokens are assumed to implement ordinary ERC-20 outgoing transfers, with no rebases, taxes or dishonest balance reporting. SafeERC20 validates return data; no contract can make a dishonest token implement its promised accounting. Local mocks demonstrate the application's behavior, not a live-chain attestation of token code.

## Authorization and boundary review

The EIP-712 domain binds the chain and contract. Separate type hashes bind every specified field, including caller identity in tickets. OpenZeppelin ECDSA enforces standard recovery and low-s signatures. A globally consumed nonce prevents ticket replay even after signer rotation. Market existence and finalization protect market/outcome replay. The owner can appoint a new signer but has no separate unsigned settlement path.

The owner is a constant set to the brief's address. There is no inheritance from Ownable and no transfer/renounce functionality. No application function changes token identities, the fee recipient or fee rate, moves arbitrary assets, calls arbitrary destinations, creates contracts, upgrades code, uses delegatecall/callcode, or selfdestructs. The runtime is scanned as EVM instructions, skipping PUSH data, as in the supplied protected floor.

Deadline comparisons match the API: create strictly in the future and at most seven days ahead; tickets inclusive through expiry and at most 120 seconds ahead; betting strictly before close; settlement inclusive through deadline; expiry inclusive at close plus 24 hours. Pause affects only creation and betting.

Settlement timing was tightened after independent review. A decisive outcome is accepted only at or after `closesAt`, while bets are accepted only strictly before it, so a bet and the Outcome that decides it can never be in the same block in either order; a ticket held until the result is known is refused with `BettingClosed`. Void is accepted at any time because a bet ordered ahead of it gains nothing. All settlement is refused from `closesAt + 24 hours`, the moment `expire` opens, so the two finalization paths are disjoint in time and a late signed result cannot be front-run by a loser's expiry. Tests cover both boundaries exactly (`closesAt - 1`, `closesAt`, `closesAt + 24 h - 1`, `closesAt + 24 h`), the held-ticket sequence, and the stateful handler settles only inside the window.

The signer starts as the EOA GameEscrow published as `signer()` on Ethereum when this was written; the constructor stores a constant and reads nothing. The owner is expected to confirm it against GameEscrow before opening and rotate if it changed.

Zero-share dust tickets are rejected explicitly; see the README's minimum-share assumption. Claims for losing/nonparticipating wallets succeed once with zero payment. Claim batches deliberately revert atomically on invalid or duplicate entries. These choices are documented for client implementations.

## Tools and limits

Verification uses `forge build`, `forge test` with the requester-supplied seed, and `forge fmt --check`. The tests include malicious transfer callbacks and a deployment/opcode rehearsal. Slither and Mythril are not part of this run, and the full environment-fed protected launch harness is executed by the separate verifier, not by these environment-free local tests.

Foundry's source lint warnings about timestamp comparisons correspond to the requested deadlines, not randomness. Exact token-balance equality is intentional for the required exact-transfer policy. The event-order heuristic sees signature recovery/static reads before events; those cannot mutate state, and the mutators are guarded. Checks inside the batch loop enforce its documented atomic failure semantics. These patterns were reviewed rather than removed to silence lint output.

The NIGHTSHIFT signing service, custody of its key, accurate match results/weights, choice of each market's `closesAt` as a pre-result betting cutoff, relaying results inside the 24-hour window, owner key control, live token/splitter code, final deployment manifest, deployed bytecode verification, and operational monitoring are external responsibilities. The owner should confirm the initial signer against GameEscrow before the service opens. An independent contributor should adversarially review source, manifest and privileges before live funds are accepted.
