// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BandPool} from "./BandPool.sol";
import {PoolBands} from "./PoolBands.sol";
import {CloneFactory} from "./libraries/CloneFactory.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";

/**
 * Deploys `BandPool` clones, one per pair, at a CREATE2 address salted by (base, quote).
 *
 * ## The implementation is deployed separately and passed in
 *
 * The factory used to create the implementation inside `initialize`, which embedded
 * the pool's whole creation code in this contract's bytecode -- so every byte the pool
 * grew, the factory grew too, against EIP-170. The v2 pool is larger than v1 and that
 * coupling would have put the factory over the limit. Taking the address decouples the
 * two sizes; the registry records it as `poolImplementation`.
 *
 * ## The pool's creator is whoever listed the pair
 *
 * `MatchingEngine.addPair` passes its caller, because the engine itself records no pair
 * creator. For a launch that caller is `AssetGenerator`, which hands the pool on to the
 * launcher with `BandPool.transferCreator` in the same transaction. `defaultCreator`
 * only covers a caller that passes zero.
 *
 * A new pool's limits are zero, so every band is idle until the engine sets the pair's
 * spread -- which `addPair` does in the same transaction, syncing the pool as it does.
 */
contract BandPoolFactory is IPoolFactory, Initializable, AccessControl {
    uint32 private constant DENOM = 100000000;

    address[] public allPools;
    address public override engine;
    address public override positionManager;
    address public override impl;

    /// Who a new pool names as its creator, until that pool hands the right on.
    address public defaultCreator;
    /// How long fees take to fully vest. 600 = ten minutes.
    uint64 public defaultMaturity;
    uint32[] private _defaultSpreadFracs;
    uint32[] private _defaultFeeMultipliers;

    error InvalidAccess(address sender, address allowed);
    error PoolAlreadyExists(address base, address quote, address pool);
    error ZeroAddress();

    /// The one place a pool address is bound to its (base, quote) pair.
    event PoolCreated(
        address indexed pool,
        address indexed base,
        address indexed quote,
        uint256 poolId,
        address orderbook,
        address creator,
        uint64 maturity
    );
    event DefaultsSet(address creator, uint64 maturity, uint32[] spreadFracs, uint32[] feeMultipliers);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address engine_, address positionManager_, address impl_, address defaultCreator_)
        public
        initializer
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            engine_ == address(0) || positionManager_ == address(0) || impl_ == address(0)
                || defaultCreator_ == address(0)
        ) revert ZeroAddress();
        engine = engine_;
        positionManager = positionManager_;
        impl = impl_;
        defaultCreator = defaultCreator_;
        defaultMaturity = 600;
        // 20% / 60% / 100% of the pair's limit -- the ratios the v1 ladder shipped with
        // (0.10 / 0.30 / 0.50%), now held as ratios so the ladder follows the limit.
        _defaultSpreadFracs.push(20000000);
        _defaultSpreadFracs.push(60000000);
        _defaultSpreadFracs.push(100000000);
        // 1x / 2x / 3x the engine's taker fee. A wide band fills only when a trade has
        // exhausted every tighter one, so at a flat rate its LPs leave and take with them
        // the depth large trades rely on. Every band is still capped at MAX_FEE_RATE.
        _defaultFeeMultipliers.push(100000000);
        _defaultFeeMultipliers.push(200000000);
        _defaultFeeMultipliers.push(300000000);
    }

    /**
     * Change what FUTURE pools are born with. Existing pools are untouched: their creator
     * owns `configureBands`. Validated here so a bad default fails on the admin's
     * transaction, not on the next pair creation.
     */
    function setDefaults(
        address creator_,
        uint64 maturity_,
        uint32[] calldata spreadFracs_,
        uint32[] calldata feeMultipliers_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (creator_ == address(0)) revert ZeroAddress();
        if (spreadFracs_.length != feeMultipliers_.length) {
            revert PoolBands.MultipliersLengthMismatch(spreadFracs_.length, feeMultipliers_.length);
        }
        if (spreadFracs_.length == 0 || spreadFracs_.length > 8) revert PoolBands.TooManyBands(spreadFracs_.length);
        for (uint256 i = 0; i < spreadFracs_.length; i++) {
            if (spreadFracs_[i] == 0 || spreadFracs_[i] > DENOM) revert PoolBands.BadSpreadFrac(spreadFracs_[i]);
            if (i > 0 && spreadFracs_[i] <= spreadFracs_[i - 1]) revert PoolBands.SpreadFracsNotAscending();
            if (feeMultipliers_[i] < DENOM) revert PoolBands.BadFeeMultiplier(feeMultipliers_[i]);
        }
        defaultCreator = creator_;
        defaultMaturity = maturity_;
        delete _defaultSpreadFracs;
        delete _defaultFeeMultipliers;
        for (uint256 i = 0; i < spreadFracs_.length; i++) {
            _defaultSpreadFracs.push(spreadFracs_[i]);
            _defaultFeeMultipliers.push(feeMultipliers_[i]);
        }
        emit DefaultsSet(creator_, maturity_, spreadFracs_, feeMultipliers_);
    }

    function defaultSpreadFracs() external view returns (uint32[] memory) {
        return _defaultSpreadFracs;
    }

    function defaultFeeMultipliers() external view returns (uint32[] memory) {
        return _defaultFeeMultipliers;
    }

    function createPool(address base_, address quote_, address orderbook_, address creator_)
        external
        override
        returns (address pool)
    {
        if (creator_ == address(0)) creator_ = defaultCreator;
        if (msg.sender != engine) revert InvalidAccess(msg.sender, engine);
        address predicted = _predictAddress(base_, quote_);
        if (predicted.code.length > 0) revert PoolAlreadyExists(base_, quote_, predicted);

        pool = CloneFactory._createCloneWithSalt(impl, _getSalt(base_, quote_));
        BandPool(pool).initialize(
            BandPool.InitParams({
                id: allPools.length,
                base: base_,
                quote: quote_,
                orderbook: orderbook_,
                engine: engine,
                positionManager: positionManager,
                creator: creator_,
                maturity: defaultMaturity,
                spreadFracs: _defaultSpreadFracs,
                feeMultipliers: _defaultFeeMultipliers
            })
        );
        allPools.push(pool);
        emit PoolCreated(pool, base_, quote_, allPools.length - 1, orderbook_, creator_, defaultMaturity);
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    /// Zero until the pool exists -- callers use that to skip pairs that have none.
    function getPool(address base, address quote) external view override returns (address pool) {
        pool = _predictAddress(base, quote);
        return pool.code.length > 0 ? pool : address(0);
    }

    /**
     * Permissionless: the pool re-reads the canonical limit itself, so a caller can only
     * make it current. The engine calls this from `setSpread` and `addPair`.
     */
    function syncLimit(address base, address quote) external override {
        address pool = _predictAddress(base, quote);
        if (pool.code.length > 0) BandPool(pool).syncLimit();
    }

    function isClone(address pool) external view override returns (bool cloned) {
        cloned = CloneFactory._isClone(impl, pool);
    }

    function _predictAddress(address base_, address quote_) internal view returns (address) {
        return CloneFactory.predictAddressWithSalt(address(this), impl, _getSalt(base_, quote_));
    }

    function _getSalt(address base_, address quote_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base_, quote_));
    }
}
