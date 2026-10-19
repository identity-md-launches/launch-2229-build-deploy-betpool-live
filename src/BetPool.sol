// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BetPool
/// @notice Signed, weighted pari-mutuel markets for NIGHTSHIFT and Agent Arena.
/// @dev Amounts and shares are token base units. The two supported tokens have 18 decimals.
///      The owner must configure the NIGHTSHIFT EOA signer before any signed action can succeed.
///      No administrator can withdraw funds, change recipients, or bypass signed outcomes.
contract BetPool is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The permanent administrator; deployment factories receive no privileges.
    address public constant owner = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice The only tokens accepted by markets.
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    /// @notice Immutable destination of the fee on the losing side.
    address public constant FEE_SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    uint256 public constant IMD_HARD_CAP = 10_000 ether;
    uint256 public constant SHIFT_HARD_CAP = 500_000_000 ether;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS = 10_000;
    uint16 public constant MIN_WEIGHT_BPS = 500;
    uint16 public constant MAX_WEIGHT_BPS = 10_000;
    uint256 public constant MAX_MARKET_DURATION = 7 days;
    uint256 public constant MAX_TICKET_LIFETIME = 120 seconds;
    uint256 public constant REFUND_DELAY = 24 hours;

    bytes32 public constant MARKET_TYPEHASH =
        keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)");
    bytes32 public constant TICKET_TYPEHASH = keccak256(
        "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
    );
    bytes32 public constant OUTCOME_TYPEHASH = keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)");

    struct Market {
        address token;
        uint64 closesAt;
        bytes32 game;
        uint256 totalA;
        uint256 totalB;
        uint256 sharesA;
        uint256 sharesB;
        bool settled;
        uint8 outcome;
        bool refundable;
    }

    struct Bet {
        uint256 amountA;
        uint256 amountB;
        uint256 sharesA;
        uint256 sharesB;
        bool claimed;
    }

    struct Limits {
        uint256 min;
        uint256 max;
    }

    /// @notice Current NIGHTSHIFT EOA signing markets, tickets and outcomes; initially unconfigured.
    address public signer;
    /// @notice Market metadata, stakes, shares and final status in the order specified by the API.
    mapping(bytes32 marketId => Market) public markets;
    /// @notice Aggregated stakes, shares and claim status for each market and wallet.
    mapping(bytes32 marketId => mapping(address bettor => Bet)) public betsOf;
    /// @notice Current inclusive per-bet bounds, in token base units.
    mapping(address token => Limits) public limits;
    /// @notice Ticket nonces are consumed globally across all markets, bettors and signer rotations.
    mapping(bytes32 nonce => bool) public usedNonce;
    /// @notice Unpaid funds belonging to this market, including rounding dust; donations are excluded.
    mapping(bytes32 marketId => uint256) public marketBalance;

    error OnlyOwner();
    error SignerNotConfigured();
    error InvalidSigner();
    error InvalidSignature();
    error UnsupportedToken();
    error InvalidLimits();
    error MarketAlreadyExists();
    error UnknownMarket();
    error InvalidCloseTime();
    error MarketAlreadySettled();
    error MarketNotSettled();
    error BettingClosed();
    error InvalidSide();
    error InvalidOutcome();
    error AmountOutsideLimits();
    error InvalidWeight();
    error InvalidTicketExpiry();
    error NonceAlreadyUsed();
    error ZeroShares();
    error InexactTransfer();
    error OutcomeExpired();
    error TooEarlyToExpire();
    error AlreadyClaimed();

    event MarketCreated(bytes32 indexed marketId, address indexed token, uint64 closesAt, bytes32 game);
    event BetPlaced(
        bytes32 indexed marketId,
        address indexed bettor,
        uint8 indexed side,
        uint256 amount,
        uint16 weightBps,
        uint256 shares
    );
    event Settled(bytes32 indexed marketId, uint8 outcome, uint256 fee);
    event Claimed(bytes32 indexed marketId, address indexed bettor, uint256 amount);
    event Expired(bytes32 indexed marketId);
    event SignerSet(address indexed signer);
    event LimitsSet(address indexed token, uint256 min, uint256 max);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Deploys with fixed addresses and default limits; no external calls or constructor arguments.
    /// @dev IMD: 0.1–500 tokens. SHIFT: 1,000–25,000,000 tokens. Signer activation is owner-only.
    constructor() EIP712("NightshiftBets", "1") {
        _setLimits(IMD, 0.1 ether, 500 ether);
        _setLimits(SHIFT, 1_000 ether, 25_000_000 ether);
    }

    /// @notice Configures or rotates the trusted signing key. Existing unused signatures from old keys stop working.
    /// @param newSigner The actual NIGHTSHIFT EOA result signer, obtained from the NIGHTSHIFT operator.
    function setSigner(address newSigner) external nonReentrant onlyOwner {
        if (newSigner == address(0)) revert InvalidSigner();
        signer = newSigner;
        emit SignerSet(newSigner);
    }

    /// @notice Changes inclusive limits for future bets, never above the token's fixed hard cap.
    /// @dev Does not change existing stakes. Tickets yielding zero integer shares cannot be accepted.
    function setLimits(address token, uint256 min, uint256 max) external nonReentrant onlyOwner {
        _setLimits(token, min, max);
    }

    /// @notice Stops new markets and bets. Settlement, expiry and claims remain available.
    function pause() external nonReentrant onlyOwner {
        _pause();
    }

    /// @notice Resumes new markets and bets.
    function unpause() external nonReentrant onlyOwner {
        _unpause();
    }

    /// @notice Creates a new market authorized by a signed Market message; anyone can relay it.
    /// @param marketId A unique identifier, never reusable even after settlement.
    /// @param token IMD or SHIFT; one token per market.
    /// @param closesAt Exclusive betting cutoff, strictly future and at most seven days away.
    /// @param game Opaque game identifier agreed with the NIGHTSHIFT backend.
    /// @param sig A 65-byte EIP-712 ECDSA signature from the configured signer.
    function createMarket(bytes32 marketId, address token, uint64 closesAt, bytes32 game, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
    {
        if (markets[marketId].token != address(0)) revert MarketAlreadyExists();
        _hardCap(token);
        if (closesAt <= block.timestamp || uint256(closesAt) > block.timestamp + MAX_MARKET_DURATION) {
            revert InvalidCloseTime();
        }
        _verify(keccak256(abi.encode(MARKET_TYPEHASH, marketId, token, closesAt, game)), sig);
        Market storage market = markets[marketId];
        market.token = token;
        market.closesAt = closesAt;
        market.game = game;
        emit MarketCreated(marketId, token, closesAt, game);
    }

    /// @notice Deposits a signed bet for the caller; repeated bets and betting on both sides are allowed.
    /// @dev The nonce and accounting are updated before transferFrom, with full rollback on a failed/inexact transfer.
    /// @param side 0 for A, 1 for B.
    /// @param amount Stake in token base units, within the token's current limits.
    /// @param weightBps Signed weight, inclusive range 500–10,000.
    /// @param expiry Inclusive deadline, no later than 120 seconds from the current block timestamp.
    /// @param nonce Globally unique ticket nonce.
    function bet(
        bytes32 marketId,
        uint8 side,
        uint256 amount,
        uint16 weightBps,
        uint64 expiry,
        bytes32 nonce,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (block.timestamp >= market.closesAt) revert BettingClosed();
        if (side > 1) revert InvalidSide();
        Limits memory bounds = limits[market.token];
        if (amount < bounds.min || amount > bounds.max) revert AmountOutsideLimits();
        if (weightBps < MIN_WEIGHT_BPS || weightBps > MAX_WEIGHT_BPS) revert InvalidWeight();
        if (expiry < block.timestamp || uint256(expiry) > block.timestamp + MAX_TICKET_LIFETIME) {
            revert InvalidTicketExpiry();
        }
        if (usedNonce[nonce]) revert NonceAlreadyUsed();
        _verify(
            keccak256(abi.encode(TICKET_TYPEHASH, marketId, msg.sender, side, amount, weightBps, expiry, nonce)), sig
        );

        // The per-bet hard caps bound this multiplication well below uint256's limit.
        uint256 shares = amount * weightBps / BPS;
        // Relevant only if the owner reduces a minimum below 20 base units. A nonempty
        // winning side must have positive shares for pro-rata settlement to be defined.
        if (shares == 0) revert ZeroShares();
        IERC20 token = IERC20(market.token);
        uint256 beforeBalance = token.balanceOf(address(this));

        usedNonce[nonce] = true;
        _recordBet(marketId, side, amount, shares);
        emit BetPlaced(marketId, msg.sender, side, amount, weightBps, shares);
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
    }

    /// @notice Finalizes immediately using a signed Outcome; anyone may relay, even before closesAt or while paused.
    /// @dev Void or either empty side refunds every stake. Otherwise only the losing side pays a 5% fee.
    /// @param outcome 0 for A, 1 for B, 2 for void.
    /// @param deadline Inclusive signature deadline; the signer determines its lifetime.
    function settle(bytes32 marketId, uint8 outcome, uint256 deadline, bytes calldata sig) external nonReentrant {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (outcome > 2) revert InvalidOutcome();
        if (deadline < block.timestamp) revert OutcomeExpired();
        _verify(keccak256(abi.encode(OUTCOME_TYPEHASH, marketId, outcome, deadline)), sig);

        market.settled = true;
        market.outcome = outcome;
        market.refundable = outcome == 2 || market.totalA == 0 || market.totalB == 0;
        uint256 fee = 0;
        if (!market.refundable) {
            uint256 losingTotal = outcome == 0 ? market.totalB : market.totalA;
            // floor(5% * losingTotal), without an overflowing intermediate multiplication.
            fee = losingTotal / 20;
            marketBalance[marketId] -= fee;
        }
        emit Settled(marketId, outcome, fee);
        if (fee != 0) IERC20(market.token).safeTransfer(FEE_SPLITTER, fee);
    }

    /// @notice Makes an unsettled market refundable at or after closesAt + 24 hours, without a signature or fee.
    /// @dev Expiry records outcome 2 (void); a later signed settlement cannot replace it.
    function expire(bytes32 marketId) external nonReentrant {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (block.timestamp < uint256(market.closesAt) + REFUND_DELAY) revert TooEarlyToExpire();
        market.settled = true;
        market.outcome = 2;
        market.refundable = true;
        emit Expired(marketId);
    }

    /// @notice Pays the caller once. A losing wallet receives zero and is marked claimed.
    /// @return amount Tokens paid, in base units.
    function claim(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        return _claim(marketId, msg.sender);
    }

    /// @notice Claims each market for the caller, including mixed-token markets, atomically.
    /// @dev Unknown, unsettled, already-claimed or duplicate entries revert the entire batch.
    ///      Empty arrays succeed. Callers should split large lists to fit their gas budget.
    function claimMany(bytes32[] calldata marketIds) external nonReentrant {
        for (uint256 i; i < marketIds.length; ++i) {
            _claim(marketIds[i], msg.sender);
        }
    }

    /// @notice Current payout; zero for unknown/unsettled markets, prior claims and losing-only wallets.
    /// @dev Rounds the bonus down once per winning wallet, leaving less than one base unit per winner as dust.
    function claimable(bytes32 marketId, address bettor) public view returns (uint256) {
        Market storage market = markets[marketId];
        Bet storage position = betsOf[marketId][bettor];
        if (!market.settled || position.claimed) return 0;
        if (market.refundable) return position.amountA + position.amountB;
        uint256 principal = market.outcome == 0 ? position.amountA : position.amountB;
        uint256 shares = market.outcome == 0 ? position.sharesA : position.sharesB;
        uint256 winningShares = market.outcome == 0 ? market.sharesA : market.sharesB;
        uint256 losingTotal = market.outcome == 0 ? market.totalB : market.totalA;
        return principal + Math.mulDiv(losingTotal - losingTotal / 20, shares, winningShares);
    }

    /// @notice EIP-712 domain separator for the current chain and this deployment.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _claim(bytes32 marketId, address bettor) private returns (uint256 amount) {
        Market storage market = _market(marketId);
        if (!market.settled) revert MarketNotSettled();
        Bet storage position = betsOf[marketId][bettor];
        if (position.claimed) revert AlreadyClaimed();
        amount = claimable(marketId, bettor);
        position.claimed = true;
        // This separate market ledger prevents any claim from consuming another market's pot.
        marketBalance[marketId] -= amount;
        emit Claimed(marketId, bettor, amount);
        if (amount != 0) IERC20(market.token).safeTransfer(bettor, amount);
    }

    function _recordBet(bytes32 marketId, uint8 side, uint256 amount, uint256 shares) private {
        Market storage market = markets[marketId];
        Bet storage position = betsOf[marketId][msg.sender];
        if (side == 0) {
            market.totalA += amount;
            market.sharesA += shares;
            position.amountA += amount;
            position.sharesA += shares;
        } else {
            market.totalB += amount;
            market.sharesB += shares;
            position.amountB += amount;
            position.sharesB += shares;
        }
        marketBalance[marketId] += amount;
    }

    function _market(bytes32 marketId) private view returns (Market storage market) {
        market = markets[marketId];
        if (market.token == address(0)) revert UnknownMarket();
    }

    function _verify(bytes32 structHash, bytes calldata sig) private view {
        address configuredSigner = signer;
        if (configuredSigner == address(0)) revert SignerNotConfigured();
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), sig);
        if (error != ECDSA.RecoverError.NoError || recovered != configuredSigner) revert InvalidSignature();
    }

    function _setLimits(address token, uint256 min, uint256 max) private {
        uint256 cap = _hardCap(token);
        if (min == 0 || min > max || max > cap) revert InvalidLimits();
        limits[token] = Limits(min, max);
        emit LimitsSet(token, min, max);
    }

    function _hardCap(address token) private pure returns (uint256) {
        if (token == IMD) return IMD_HARD_CAP;
        if (token == SHIFT) return SHIFT_HARD_CAP;
        revert UnsupportedToken();
    }
}
