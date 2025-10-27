// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC1155Upgradeable, ERC1155SupplyUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// PRBMath UD60x18
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {ln, exp} from "@prb/math/src/ud60x18/Math.sol";

/**
 * @title LMSR AMM with reusable ERC1155 outcome shares
 * @author Timeless Market Team
 * @notice Multi-market binary prediction AMM.
 *         Each market m has two ERC1155 tokenIds:
 *            YES id  = marketId << 1 | 1
 *            NO  id  = marketId << 1 | 0
 */
contract Lmsr1155Markets is
    AccessControlEnumerableUpgradeable,
    ERC1155SupplyUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    // ----- Roles -----
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");
    bytes32 public constant MARKET_CREATOR_ROLE =
        keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ----- Constants -----
    uint256 public constant BASIS_POINTS = 1e4;
    /// @notice Safe upper bound for exp(x) input in UD60x18 (1e18 scale)
    uint256 private constant MAX_NATURAL_EXPONENT_WAD = 133084258667509499441;
    /// @notice Soft clamps to avoid returning exact 0 or 1 for prices
    uint256 private constant MIN_PRICE_WAD = 1; // 1 wei of price
    uint256 private constant MAX_PRICE_WAD = 1e18 - 1; // 0.999... (avoid 1 exactly)
    /// @notice Natural log of 2 in wad precision (1e18)
    uint256 private constant LN2_WAD = 693147180559945309;

    // ----- Core config -----
    /// @notice Base URI used when a market-specific URI is not provided.
    string public baseURI;

    /// @notice Fee (in basis points) and the treasury account collecting it.
    uint256 public feeBps; // e.g., 20 = 0.20%
    address public feeRecipient; // treasury address

    // ----- Types -----
    enum Outcome {
        Undecided,
        Yes,
        No,
        Invalid
    }

    struct Market {
        // LMSR state (wad 1e18)
        uint256 qYes; // cumulative YES shares sold by AMM
        uint256 qNo; // cumulative NO shares sold by AMM
        uint256 b; // liquidity parameter (wad)
        // Config
        IERC20 collateral; // e.g., USDC
        address oracle; // address allowed to resolve
        uint64 closeTime; // unix seconds
        Outcome outcome; // resolved state
        bool exists;
    }

    // ----- Storage -----
    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets; // marketId => Market

    // Optional metadata per market for off-chain indexers
    mapping(uint256 => string) public marketMetadataURI;

    // ----- Events -----
    event MarketCreated(
        uint256 indexed marketId,
        address collateral,
        uint256 b,
        uint64 closeTime,
        address oracle,
        string uri
    );
    event Bought(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 sharesWad,
        uint256 costWad
    );
    event Sold(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 sharesWad,
        uint256 payoutWad
    );
    event Resolved(uint256 indexed marketId, Outcome outcome);
    event Redeemed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payoutWad
    );
    event FeeCollected(
        uint256 indexed marketId,
        address indexed user,
        bool isBuy,
        bool isYes,
        uint256 feeWad
    );
    event FeeConfigSet(uint256 feeBps, address feeRecipient);

    // ----- Initializer -----
    /**
     * @notice Initializes roles, metadata base URI, and fee configuration.
     * @param _baseURI Fallback metadata base URI for all outcome tokens.
     * @param _feeBps Fee configured in basis points (1e4 = 100%).
     * @param _feeRecipient Address receiving accrued protocol fees.
     */
    function initialize(
        string memory _baseURI,
        uint256 _feeBps,
        address _feeRecipient,
        address _admin
    ) public initializer {
        require(_feeBps <= BASIS_POINTS, "fee exceeds maximum");
        require(_feeRecipient != address(0), "fee recipient is zero address");

        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();

        baseURI = _baseURI;
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_SETTER_ROLE, _admin);
        _grantRole(MARKET_CREATOR_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // ======== Admin Controls ========

    /**
     * @notice Set fee configuration. Applies symmetrically to buys and sells.
     * @param _feeBps Fee in basis points (1e4 = 100%).
     * @param _feeRecipient Address to receive fees.
     */
    function setFeeConfig(
        uint256 _feeBps,
        address _feeRecipient
    ) public onlyRole(FEE_SETTER_ROLE) {
        require(_feeBps <= BASIS_POINTS, "fee exceeds maximum");
        require(_feeRecipient != address(0), "fee recipient is zero address");

        feeBps = _feeBps;
        feeRecipient = _feeRecipient;

        emit FeeConfigSet(_feeBps, _feeRecipient);
    }

    /**
     * @notice Pause trading, creation, and resolution interactions.
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resume trading after a pause.
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Set the base metadata URI for all markets.
     * @param _baseURI Fallback metadata base URI for all outcome tokens.
     */
    function setBaseURI(
        string memory _baseURI
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = _baseURI;
    }

    // ======== Market Lifecycle ========

    /**
     * @notice Create a new binary market.
     * @param collateral ERC20 collateral (e.g., USDC on Polygon).
     * @param bWad LMSR liquidity parameter (wad). Example: 5e18.
     * @param closeTime Unix seconds when trading closes.
     * @param oracle Address allowed to resolve this market.
     * @param metadataURI Optional per-market metadata URI (ipfs/http).
     * @return marketId Newly created market identifier.
     */
    function createMarket(
        IERC20 collateral,
        uint256 bWad,
        uint64 closeTime,
        address oracle,
        string calldata metadataURI
    ) external onlyRole(MARKET_CREATOR_ROLE) returns (uint256 marketId) {
        require(
            address(collateral) != address(0),
            "collateral is zero address"
        );
        require(bWad > 0, "liquidity parameter is zero");
        require(oracle != address(0), "oracle is zero address");
        require(closeTime > block.timestamp, "close time is in past");

        marketId = ++nextMarketId;
        markets[marketId] = Market({
            qYes: 0,
            qNo: 0,
            b: bWad,
            collateral: collateral,
            oracle: oracle,
            closeTime: closeTime,
            outcome: Outcome.Undecided,
            exists: true
        });

        if (bytes(metadataURI).length != 0) {
            marketMetadataURI[marketId] = metadataURI;
        }

        emit MarketCreated(
            marketId,
            address(collateral),
            bWad,
            closeTime,
            oracle,
            metadataURI
        );
    }

    /**
     * @notice Compute the ERC1155 YES token identifier for a market.
     * @param marketId Target market.
     */
    function yesId(uint256 marketId) public pure returns (uint256) {
        return (marketId << 1) | 1;
    }

    /**
     * @notice Compute the ERC1155 NO token identifier for a market.
     * @param marketId Target market.
     */
    function noId(uint256 marketId) public pure returns (uint256) {
        return (marketId << 1) | 0;
    }

    // ======== Market Views & Pricing ========

    /// @dev Clamp price into (0,1) open interval in wad precision to avoid exact 0/1 due to flooring.
    function _clampPrice(uint256 pWad) internal pure returns (uint256) {
        if (pWad <= MIN_PRICE_WAD) return MIN_PRICE_WAD;
        if (pWad >= 1e18) return MAX_PRICE_WAD;
        return pWad;
    }

    /// @dev Compute price of YES using a numerically stable form: p = exp(Δ) / (1 + exp(Δ)), where Δ=(qYes-qNo)/b.
    ///      Since UD60x18 is unsigned, handle sign by taking the larger of a=qYes/b and c=qNo/b.
    ///      Also clamp extreme Δ using MAX_NATURAL_EXPONENT_WAD to avoid huge exp values.
    function _priceYesStable(
        uint256 qYesWad,
        uint256 qNoWad,
        uint256 bWad
    ) internal pure returns (uint256) {
        UD60x18 a = ud(qYesWad).div(ud(bWad));
        UD60x18 c = ud(qNoWad).div(ud(bWad));
        UD60x18 one = ud(1e18);
        UD60x18 t;

        if (a.unwrap() >= c.unwrap()) {
            UD60x18 delta = a.sub(c);
            if (delta.unwrap() >= MAX_NATURAL_EXPONENT_WAD) {
                // exp(delta) is astronomically large ⇒ price ~= 1
                return MAX_PRICE_WAD;
            }
            t = exp(delta);
        } else {
            UD60x18 delta = c.sub(a);
            if (delta.unwrap() >= MAX_NATURAL_EXPONENT_WAD) {
                // exp(-delta) ~= 0 ⇒ price ~= 0
                return MIN_PRICE_WAD;
            }
            t = one.div(exp(delta));
        }

        UD60x18 p = t.div(one.add(t));
        return _clampPrice(p.unwrap());
    }

    /**
     * @notice Return the current status and configuration of a market.
     * @param marketId Target market identifier.
     * @return outc Resolution outcome.
     * @return bWad LMSR liquidity parameter in wad units.
     * @return qYesWad YES inventory accumulated by the AMM in wad.
     * @return qNoWad NO inventory accumulated by the AMM in wad.
     * @return collateral Collateral token address.
     * @return closeTime Unix timestamp when the market closes.
     * @return oracle Address authorized to resolve the market.
     */
    function marketStatus(
        uint256 marketId
    )
        external
        view
        returns (
            Outcome outc,
            uint256 bWad,
            uint256 qYesWad,
            uint256 qNoWad,
            address collateral,
            uint64 closeTime,
            address oracle
        )
    {
        Market storage m = _marketExisting(marketId);
        return (
            m.outcome,
            m.b,
            m.qYes,
            m.qNo,
            address(m.collateral),
            m.closeTime,
            m.oracle
        );
    }

    /**
     * @notice Optional per-market metadata override.
     * @dev Returns `baseURI + metadataURI` when available, otherwise falls back to ERC1155 standard behaviour.
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        uint256 marketId = tokenId >> 1;
        string memory tokenURI = marketMetadataURI[marketId];

        if (bytes(tokenURI).length > 0) {
            return
                string.concat(
                    baseURI,
                    tokenURI,
                    "/",
                    Strings.toString(tokenId)
                );
        }

        return super.uri(tokenId);
    }

    /**
     * @notice LMSR price of YES for a market. Accepts resolved markets for post-settlement analytics.
     * @param marketId Target market identifier.
     * @return pYesWad Price of YES in wad precision (1e18 = 1.0).
     */
    function priceYes(
        uint256 marketId
    ) external view returns (uint256 pYesWad) {
        Market storage m = _marketOpenOrResolved(marketId);
        return _priceYesStable(m.qYes, m.qNo, m.b);
    }

    /**
     * @notice LMSR price of NO for a market. Accepts resolved markets for post-settlement analytics.
     * @param marketId Target market identifier.
     * @return pNoWad Price of NO in wad precision (1e18 = 1.0).
     */
    function priceNo(uint256 marketId) external view returns (uint256 pNoWad) {
        Market storage m = _marketOpenOrResolved(marketId);
        uint256 pYes = _priceYesStable(m.qYes, m.qNo, m.b);
        // pNo = 1 - pYes, then clamp away exact 0/1
        uint256 raw = 1e18 - pYes;
        return _clampPrice(raw);
    }

    /**
     * @notice Quote the cost (without fees) to buy additional YES shares.
     * @param marketId Target market identifier.
     * @param deltaSharesWad Amount of YES shares in wad precision.
     * @return costWad LMSR cost excluding fees in wad precision.
     */
    function quoteBuyYes(
        uint256 marketId,
        uint256 deltaSharesWad
    ) external view returns (uint256 costWad) {
        Market storage m = _marketOpen(marketId);
        uint256 c1 = _C(m.qYes + deltaSharesWad, m.qNo, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        return c1 - c0;
    }

    /**
     * @notice Quote the cost (without fees) to buy additional NO shares.
     */
    function quoteBuyNo(
        uint256 marketId,
        uint256 deltaSharesWad
    ) external view returns (uint256 costWad) {
        Market storage m = _marketOpen(marketId);
        uint256 c1 = _C(m.qYes, m.qNo + deltaSharesWad, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        return c1 - c0;
    }

    /**
     * @notice Quote the payout (without fees) for selling YES shares.
     */
    function quoteSellYes(
        uint256 marketId,
        uint256 deltaSharesWad
    ) external view returns (uint256 payoutWad) {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");
        require(deltaSharesWad <= m.qYes, "sell amount exceeds yes inventory");
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes - deltaSharesWad, m.qNo, m.b);
        return c0 - c1;
    }

    /**
     * @notice Quote the payout (without fees) for selling NO shares.
     */
    function quoteSellNo(
        uint256 marketId,
        uint256 deltaSharesWad
    ) external view returns (uint256 payoutWad) {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");
        require(deltaSharesWad <= m.qNo, "sell amount exceeds no inventory");
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes, m.qNo - deltaSharesWad, m.b);
        return c0 - c1;
    }

    /**
     * @notice Quote the cost and fee for buying YES shares.
     * @return costWad Net LMSR cost excluding fees.
     * @return feeWad Fee charged in wad precision.
     * @return totalWad Total user payment (cost + fee).
     */
    function quoteBuyYesWithFee(
        uint256 marketId,
        uint256 deltaSharesWad
    )
        external
        view
        returns (uint256 costWad, uint256 feeWad, uint256 totalWad)
    {
        Market storage m = _marketOpen(marketId);
        uint256 c1 = _C(m.qYes + deltaSharesWad, m.qNo, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        costWad = c1 - c0;
        feeWad = _calcFeeWad(costWad);
        totalWad = costWad + feeWad;
    }

    /**
     * @notice Quote the cost and fee for buying NO shares.
     */
    function quoteBuyNoWithFee(
        uint256 marketId,
        uint256 deltaSharesWad
    )
        external
        view
        returns (uint256 costWad, uint256 feeWad, uint256 totalWad)
    {
        Market storage m = _marketOpen(marketId);
        uint256 c1 = _C(m.qYes, m.qNo + deltaSharesWad, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        costWad = c1 - c0;
        feeWad = _calcFeeWad(costWad);
        totalWad = costWad + feeWad;
    }

    /**
     * @notice Quote payout and fee for selling YES shares.
     * @return grossPayoutWad Payout before fees.
     * @return feeWad Fee charged in wad precision.
     * @return netPayoutWad Payout after fee deduction.
     */
    function quoteSellYesWithFee(
        uint256 marketId,
        uint256 deltaSharesWad
    )
        external
        view
        returns (uint256 grossPayoutWad, uint256 feeWad, uint256 netPayoutWad)
    {
        Market storage m = _marketOpen(marketId);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes - deltaSharesWad, m.qNo, m.b);
        grossPayoutWad = c0 - c1;
        feeWad = _calcFeeWad(grossPayoutWad);
        netPayoutWad = grossPayoutWad - feeWad;
    }

    /**
     * @notice Quote payout and fee for selling NO shares.
     */
    function quoteSellNoWithFee(
        uint256 marketId,
        uint256 deltaSharesWad
    )
        external
        view
        returns (uint256 grossPayoutWad, uint256 feeWad, uint256 netPayoutWad)
    {
        Market storage m = _marketOpen(marketId);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes, m.qNo - deltaSharesWad, m.b);
        grossPayoutWad = c0 - c1;
        feeWad = _calcFeeWad(grossPayoutWad);
        netPayoutWad = grossPayoutWad - feeWad;
    }

    /**
     * @notice Quote how many YES shares you receive for spending a given cost (excluding fees).
     * @param marketId Target market identifier.
     * @param costWad Budget to spend on LMSR cost (wad, excludes fee).
     * @return sharesWad The number of YES shares purchasable for `costWad`.
     */
    function quoteBuyYesForCost(
        uint256 marketId,
        uint256 costWad
    ) external view returns (uint256 sharesWad) {
        Market storage m = _marketOpen(marketId);
        require(costWad > 0, "cost amount is zero");
        sharesWad = _solveDeltaForCost(m.qYes, m.qNo, m.b, costWad);
    }

    /**
     * @notice Quote how many NO shares you receive for spending a given cost (excluding fees).
     * @param marketId Target market identifier.
     * @param costWad Budget to spend on LMSR cost (wad, excludes fee).
     * @return sharesWad The number of NO shares purchasable for `costWad`.
     */
    function quoteBuyNoForCost(
        uint256 marketId,
        uint256 costWad
    ) external view returns (uint256 sharesWad) {
        Market storage m = _marketOpen(marketId);
        require(costWad > 0, "cost amount is zero");
        sharesWad = _solveDeltaForCost(m.qNo, m.qYes, m.b, costWad);
    }

    // ======== Trading ========

    /**
     * @notice Buy YES shares from the AMM at the current LMSR price.
     * @param marketId Target market.
     * @param deltaSharesWad Desired shares (wad, 1e18 = 1.0).
     * @param maxCostWad Slippage guard in wad.
     */
    function buyYes(
        uint256 marketId,
        uint256 deltaSharesWad,
        uint256 maxCostWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");

        uint256 c1 = _C(m.qYes + deltaSharesWad, m.qNo, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 costWad = c1 - c0;
        require(costWad <= maxCostWad, "cost exceeds maximum allowed");

        // Fee on top of cost
        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(costWad);
        uint256 totalWad = costWad + feeWad;

        _pullCollateralWad(m.collateral, msg.sender, totalWad);
        _payFeeWad(m.collateral, feeWad, dec, marketId, msg.sender, true, true);

        m.qYes += deltaSharesWad;

        // Mint YES shares to user (ERC1155 uses raw units with 18 decimals here).
        _mint(msg.sender, yesId(marketId), _wadToToken(deltaSharesWad, 18), "");
        emit Bought(marketId, msg.sender, true, deltaSharesWad, costWad);
    }

    /**
     * @notice Buy NO shares from the AMM at the current LMSR price.
     */
    function buyNo(
        uint256 marketId,
        uint256 deltaSharesWad,
        uint256 maxCostWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");

        uint256 c1 = _C(m.qYes, m.qNo + deltaSharesWad, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 costWad = c1 - c0;
        require(costWad <= maxCostWad, "cost exceeds maximum allowed");

        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(costWad);
        uint256 totalWad = costWad + feeWad;

        _pullCollateralWad(m.collateral, msg.sender, totalWad);
        _payFeeWad(
            m.collateral,
            feeWad,
            dec,
            marketId,
            msg.sender,
            true,
            false
        );

        m.qNo += deltaSharesWad;

        _mint(msg.sender, noId(marketId), _wadToToken(deltaSharesWad, 18), "");
        emit Bought(marketId, msg.sender, false, deltaSharesWad, costWad);
    }

    /**
     * @notice Buy YES shares by specifying the LMSR cost budget (excludes fee).
     * @param marketId Target market.
     * @param costWad Budget to spend on LMSR cost in wad (fee is charged on top).
     * @param minSharesWad Minimum shares expected (slippage guard).
     */
    function buyYesForCost(
        uint256 marketId,
        uint256 costWad,
        uint256 minSharesWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(costWad > 0, "cost amount is zero");

        // Solve for shares so that C(qYes+Δ,qNo)-C(qYes,qNo) ≈ costWad
        uint256 deltaSharesWad = _solveDeltaForCost(
            m.qYes,
            m.qNo,
            m.b,
            costWad
        );
        require(
            deltaSharesWad >= minSharesWad,
            "shares below minimum required"
        );

        // Recompute actual cost for the solved delta (never exceeds target by construction)
        uint256 c1 = _C(m.qYes + deltaSharesWad, m.qNo, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 actualCostWad = c1 - c0;
        require(actualCostWad <= costWad, "actual cost exceeds budget");

        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(actualCostWad);
        uint256 totalWad = actualCostWad + feeWad;

        _pullCollateralWad(m.collateral, msg.sender, totalWad);
        _payFeeWad(m.collateral, feeWad, dec, marketId, msg.sender, true, true);

        m.qYes += deltaSharesWad;
        _mint(msg.sender, yesId(marketId), _wadToToken(deltaSharesWad, 18), "");
        emit Bought(marketId, msg.sender, true, deltaSharesWad, actualCostWad);
    }

    /**
     * @notice Buy NO shares by specifying the LMSR cost budget (excludes fee).
     * @param marketId Target market.
     * @param costWad Budget to spend on LMSR cost in wad (fee is charged on top).
     * @param minSharesWad Minimum shares expected (slippage guard).
     */
    function buyNoForCost(
        uint256 marketId,
        uint256 costWad,
        uint256 minSharesWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(costWad > 0, "cost amount is zero");

        uint256 deltaSharesWad = _solveDeltaForCost(
            m.qNo,
            m.qYes,
            m.b,
            costWad
        );
        require(
            deltaSharesWad >= minSharesWad,
            "shares below minimum required"
        );

        uint256 c1 = _C(m.qYes, m.qNo + deltaSharesWad, m.b);
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 actualCostWad = c1 - c0;
        require(actualCostWad <= costWad, "actual cost exceeds budget");

        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(actualCostWad);
        uint256 totalWad = actualCostWad + feeWad;

        _pullCollateralWad(m.collateral, msg.sender, totalWad);
        _payFeeWad(
            m.collateral,
            feeWad,
            dec,
            marketId,
            msg.sender,
            true,
            false
        );

        m.qNo += deltaSharesWad;
        _mint(msg.sender, noId(marketId), _wadToToken(deltaSharesWad, 18), "");
        emit Bought(marketId, msg.sender, false, deltaSharesWad, actualCostWad);
    }

    /**
     * @notice Sell YES shares back to the AMM at the current LMSR price.
     * @param marketId Target market.
     * @param deltaSharesWad Shares to sell (wad).
     * @param minPayoutWad Minimum payout in wad (slippage guard).
     */
    function sellYes(
        uint256 marketId,
        uint256 deltaSharesWad,
        uint256 minPayoutWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");
        require(deltaSharesWad <= m.qYes, "sell amount exceeds yes inventory");

        // Ensure user has enough YES tokens (ERC1155 uses 18 decimals as minted).
        uint256 burnAmount = _wadToToken(deltaSharesWad, 18); // identity with 18
        require(
            balanceOf(msg.sender, yesId(marketId)) >= burnAmount,
            "insufficient yes token balance"
        );

        // Payout = C(qYes, qNo) - C(qYes - delta, qNo)
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes - deltaSharesWad, m.qNo, m.b);
        uint256 payoutWad = c0 - c1;
        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(payoutWad);
        uint256 netWad = payoutWad - feeWad;
        require(netWad >= minPayoutWad, "payout below minimum required");

        // Burn user's YES and update state
        _burn(msg.sender, yesId(marketId), burnAmount);
        m.qYes -= deltaSharesWad;

        // Pay user net and send fee to treasury
        _pushCollateralWad(m.collateral, msg.sender, netWad);
        _payFeeWad(
            m.collateral,
            feeWad,
            dec,
            marketId,
            msg.sender,
            false,
            true
        );
        emit Sold(marketId, msg.sender, true, deltaSharesWad, payoutWad);
    }

    /**
     * @notice Sell NO shares back to the AMM at the current LMSR price.
     * @param marketId Target market.
     * @param deltaSharesWad Shares to sell (wad).
     * @param minPayoutWad Minimum payout in wad (slippage guard).
     */
    function sellNo(
        uint256 marketId,
        uint256 deltaSharesWad,
        uint256 minPayoutWad
    ) external nonReentrant whenNotPaused {
        Market storage m = _marketOpen(marketId);
        require(deltaSharesWad > 0, "shares amount is zero");
        require(deltaSharesWad <= m.qNo, "sell amount exceeds no inventory");

        uint256 burnAmount = _wadToToken(deltaSharesWad, 18);
        require(
            balanceOf(msg.sender, noId(marketId)) >= burnAmount,
            "insufficient no token balance"
        );

        // Payout = C(qYes, qNo) - C(qYes, qNo - delta)
        uint256 c0 = _C(m.qYes, m.qNo, m.b);
        uint256 c1 = _C(m.qYes, m.qNo - deltaSharesWad, m.b);
        uint256 payoutWad = c0 - c1;
        uint8 dec = _tryDecimals(m.collateral, 18);
        uint256 feeWad = _calcFeeWad(payoutWad);
        uint256 netWad = payoutWad - feeWad;
        require(netWad >= minPayoutWad, "payout below minimum required");

        _burn(msg.sender, noId(marketId), burnAmount);
        m.qNo -= deltaSharesWad;

        _pushCollateralWad(m.collateral, msg.sender, netWad);
        _payFeeWad(
            m.collateral,
            feeWad,
            dec,
            marketId,
            msg.sender,
            false,
            false
        );
        emit Sold(marketId, msg.sender, false, deltaSharesWad, payoutWad);
    }

    // ======== Resolution & Redemption ========

    /**
     * @notice Resolve a market to a final outcome.
     * @param marketId Target market identifier.
     * @param outc Final outcome (Yes, No, or Invalid).
     */
    function resolve(uint256 marketId, Outcome outc) external whenNotPaused {
        Market storage m = _marketExisting(marketId);
        require(msg.sender == m.oracle, "caller is not oracle");
        require(m.outcome == Outcome.Undecided, "market already resolved");
        require(
            outc == Outcome.Yes ||
                outc == Outcome.No ||
                outc == Outcome.Invalid,
            "invalid outcome value"
        );
        m.outcome = outc;
        emit Resolved(marketId, outc);
    }

    /**
     * @notice Redeem winning shares for collateral (1.0 unit per share).
     *         - YES wins: burn YES id, pay 1:1
     *         - NO  wins: burn NO  id, pay 1:1
     *         - INVALID: simple refund model = min(YES, NO)
     * @param marketId Target market identifier.
     */
    function redeem(uint256 marketId) external nonReentrant {
        Market storage m = _marketResolved(marketId);

        uint256 yesTokenBal = balanceOf(msg.sender, yesId(marketId));
        uint256 noTokenBal = balanceOf(msg.sender, noId(marketId));
        uint256 payWad;

        if (m.outcome == Outcome.Yes) {
            require(yesTokenBal > 0, "no yes tokens to redeem");
            _burn(msg.sender, yesId(marketId), yesTokenBal);
            // convert ERC1155 raw (18) -> wad (18): identity
            payWad = yesTokenBal; // because we minted with 18
        } else if (m.outcome == Outcome.No) {
            require(noTokenBal > 0, "no no tokens to redeem");
            _burn(msg.sender, noId(marketId), noTokenBal);
            payWad = noTokenBal;
        } else {
            // INVALID: proportional refund based on user's total outstanding shares
            // Pool collateral attributable to this market is C(qYes, qNo) - b * ln(2)
            uint256 poolWad = _C(m.qYes, m.qNo, m.b) - ud(m.b).mul(ud(LN2_WAD)).unwrap();
            // Total outstanding shares (wad) equals qYes + qNo (since we mint/burn with 18 decimals)
            uint256 totalSharesWad = m.qYes + m.qNo;
            require(totalSharesWad > 0, "nothing outstanding to refund");

            uint256 userYes = yesTokenBal;
            uint256 userNo = noTokenBal;
            uint256 userTotalSharesWad = userYes + userNo;
            require(userTotalSharesWad > 0, "no tokens to redeem");

            // Burn all user's outstanding YES and NO for this market
            _burn(msg.sender, yesId(marketId), userYes);
            _burn(msg.sender, noId(marketId), userNo);

            // Payout is proportional to user's share of total outstanding
            // payWad = poolWad * userTotalSharesWad / totalSharesWad
            payWad = (poolWad * userTotalSharesWad) / totalSharesWad;
        }

        _pushCollateralWad(m.collateral, msg.sender, payWad);
        emit Redeemed(marketId, msg.sender, payWad);
    }

    // ======== Internal Guards ========

    /**
     * @notice Ensure the market exists before continuing.
     */
    function _marketExisting(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = markets[marketId];
        require(m.exists, "market does not exist");
    }

    /**
     * @notice Ensure the market exists and remains open for trading.
     */
    function _marketOpen(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _marketExisting(marketId);
        require(block.timestamp < m.closeTime, "market is closed");
        require(m.outcome == Outcome.Undecided, "market already resolved");
    }

    /**
     * @notice Ensure the market is already resolved.
     */
    function _marketResolved(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _marketExisting(marketId);
        require(m.outcome != Outcome.Undecided, "market not resolved");
    }

    /**
     * @notice Ensure the market exists, regardless of whether it is open or resolved.
     */
    function _marketOpenOrResolved(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _marketExisting(marketId);
    }

    // ======== Fee Utilities ========

    /**
     * @notice Calculate the fee (in wad) from an amount quoted in wad precision.
     */
    function _calcFeeWad(uint256 amountWad) internal view returns (uint256) {
        if (feeBps == 0) return 0;
        return (amountWad * feeBps) / BASIS_POINTS;
    }

    /**
     * @notice Send collected fees to the fee recipient.
     * @dev Emits `FeeCollected` to ease off-chain accounting.
     */
    function _payFeeWad(
        IERC20 token,
        uint256 feeWad,
        uint8 tokenDecimals,
        uint256 marketId,
        address user,
        bool isBuy,
        bool isYes
    ) internal {
        if (feeWad == 0) return;
        uint256 raw = _wadToToken(feeWad, tokenDecimals);
        token.safeTransfer(feeRecipient, raw);
        emit FeeCollected(marketId, user, isBuy, isYes, feeWad);
    }

    // ======== Collateral & Decimal Utilities ========

    /**
     * @notice Pull collateral from a user using wad precision accounting.
     */
    function _pullCollateralWad(
        IERC20 token,
        address from,
        uint256 wad
    ) internal {
        uint8 dec = _tryDecimals(token, 18);
        uint256 raw = _wadToToken(wad, dec);
        token.safeTransferFrom(from, address(this), raw);
    }

    /**
     * @notice Push collateral to a user using wad precision accounting.
     */
    function _pushCollateralWad(
        IERC20 token,
        address to,
        uint256 wad
    ) internal {
        uint8 dec = _tryDecimals(token, 18);
        uint256 raw = _wadToToken(wad, dec);
        token.safeTransfer(to, raw);
    }

    /**
     * @notice Convert wad precision (1e18) amounts to token decimals.
     */
    function _wadToToken(
        uint256 wad,
        uint8 tokenDecimals
    ) internal pure returns (uint256) {
        if (tokenDecimals == 18) return wad;
        if (tokenDecimals < 18) return wad / (10 ** (18 - tokenDecimals));
        return wad * (10 ** (tokenDecimals - 18));
    }

    /**
     * @notice Convert raw token amounts into wad precision (1e18).
     */
    function _tokenToWad(
        uint256 amt,
        uint8 tokenDecimals
    ) internal pure returns (uint256) {
        if (tokenDecimals == 18) return amt;
        if (tokenDecimals < 18) return amt * (10 ** (18 - tokenDecimals));
        return amt / (10 ** (tokenDecimals - 18));
    }

    /**
     * @notice Attempt to read token decimals, using a fallback if unavailable.
     */
    function _tryDecimals(
        IERC20 token,
        uint8 fallbackDec
    ) internal view returns (uint8) {
        (bool ok, bytes memory data) = address(token).staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && data.length >= 32) {
            return uint8(uint256(bytes32(data)));
        }
        return fallbackDec; // default 18 if not implemented
    }

    // ======== LMSR Math ========

    /**
     * @notice Solve for shares Δ given target cost on an LMSR leg using monotonic binary search.
     * @dev Finds Δ >= 0 such that C(qA+Δ,qB) - C(qA,qB) <= targetCost and as tight as possible.
     *      The function first exponentially expands `hi` until cost(hi) >= targetCost (or up to 1e36),
     *      then binary searches for ~64 iterations. Pure math; uses wad precision throughout.
     */
    function _solveDeltaForCost(
        uint256 qA,
        uint256 qB,
        uint256 bWad,
        uint256 targetCost
    ) internal pure returns (uint256) {
        require(bWad > 0, "liquidity parameter is zero");
        require(targetCost > 0, "target cost is zero");

        // Handle tiny budgets: if even 1 wei of shares costs more than target, return 0
        // (caller side protects cost=0; minShares guard can be used to reject 0).
        uint256 lo = 0;
        uint256 hi = 1e9; // start with a modest step (1e9 wei of shares)

        // Exponentially increase hi until cost(hi) >= targetCost or cap out
        // Cap hi to avoid overflow: 1e36 shares in wad space is enormous and safe under UD60x18.
        while (hi < 1e36) {
            uint256 c1 = _C(qA + hi, qB, bWad);
            uint256 c0 = _C(qA, qB, bWad);
            uint256 cost = c1 - c0;
            if (cost >= targetCost) break;
            hi <<= 1; // double
        }

        // If still below target at cap, return the cap (best effort)
        {
            uint256 c1cap = _C(qA + hi, qB, bWad);
            uint256 c0cap = _C(qA, qB, bWad);
            if (c1cap - c0cap < targetCost) return hi;
        }

        // Binary search for tight Δ where cost(Δ) <= targetCost
        for (uint256 i = 0; i < 64; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 c1m = _C(qA + mid, qB, bWad);
            uint256 c0m = _C(qA, qB, bWad);
            uint256 cm = c1m - c0m;
            if (cm > targetCost) {
                hi = mid;
            } else {
                lo = mid;
            }
            if (hi - lo <= 1) break;
        }
        return lo; // maximal Δ such that cost(Δ) <= targetCost
    }

    /// @notice LMSR cost function: C(qYes, qNo) = b * ln(exp(qYes/b) + exp(qNo/b)).
    function _C(
        uint256 qYesWad,
        uint256 qNoWad,
        uint256 bWad
    ) internal pure returns (uint256) {
        require(bWad > 0, "liquidity parameter is zero");

        UD60x18 a = ud(qYesWad).div(ud(bWad));
        UD60x18 b = ud(qNoWad).div(ud(bWad));
        UD60x18 one = ud(1e18);
        UD60x18 l;

        // ln(exp(a) + exp(b)) = m + ln(1 + exp(-(m - other)))
        // Avoid negatives in UD60x18 by inversion: exp(-x) = 1 / exp(x)
        if (a.unwrap() >= b.unwrap()) {
            UD60x18 delta = a.sub(b); // delta >= 0
            if (delta.unwrap() >= MAX_NATURAL_EXPONENT_WAD) {
                l = a; // ln(1 + 1/exp(delta)) ≈ 0
            } else {
                UD60x18 term = one.add(one.div(exp(delta))); // 1 + exp(-delta)
                l = a.add(ln(term));
            }
        } else {
            UD60x18 delta = b.sub(a);
            if (delta.unwrap() >= MAX_NATURAL_EXPONENT_WAD) {
                l = b;
            } else {
                UD60x18 term = one.add(one.div(exp(delta))); // 1 + exp(-delta)
                l = b.add(ln(term));
            }
        }

        return ud(bWad).mul(l).unwrap();
    }

    // ======== Lmsr1155Markets ========

    /// @dev Override to block user transfers.
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        require(
            from == address(0) || to == address(0),
            "ERC1155: user transfers blocked"
        );

        super._update(from, to, ids, values);
    }

    /// @dev Disable approvals so users cannot delegate transfers.
    function setApprovalForAll(
        address /*operator*/,
        bool /*approved*/
    ) public pure override(ERC1155Upgradeable) {
        revert("ERC1155: approvals disabled");
    }

    // ======== Interface Support ========

    /**
     * @inheritdoc ERC1155Upgradeable
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AccessControlEnumerableUpgradeable, ERC1155Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
