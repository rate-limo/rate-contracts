// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/**
 * Uniswap v3, measured on a mainnet fork, so the numbers beside BandPool's are taken
 * the same way rather than quoted from a blog post.
 *
 * Methodology is copied from GasProbe_OrderPaths exactly: `g = gasleft()` either side
 * of ONE router call, under `isolate = true`. Both venues are measured at the router,
 * not at the pool, because that is the call a user actually sends.
 *
 * The pool is read out of the v3 factory rather than pasted in, and every address is
 * asserted to have code before it is used.
 *
 *   forge test --match-path 'test/swap/GasProbe_UniswapV3Fork.t.sol' -vv \
 *     --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26120000
 */
interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface INFPM {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

contract GasProbe_UniswapV3Fork is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 constant FEE = 500;

    address pool;
    address trader = makeAddr("trader");

    function setUp() public {
        // CI runs a plain `forge test` with no fork, where none of these addresses exist.
        // Skip rather than fail: this probe is a measurement, not a property, and it is
        // run by hand with --fork-url when the comparison needs refreshing.
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }

        // Every address asserted to exist on the fork before anything uses it.
        assertGt(USDC.code.length, 0, "USDC");
        assertGt(WETH.code.length, 0, "WETH");
        assertGt(FACTORY.code.length, 0, "factory");
        assertGt(ROUTER.code.length, 0, "router");
        assertGt(NFPM.code.length, 0, "position manager");

        pool = IV3Factory(FACTORY).getPool(USDC, WETH, FEE);
        assertGt(pool.code.length, 0, "pool");
        assertGt(IV3Pool(pool).liquidity(), 0, "pool has liquidity");
    }

    function _swap(uint256 amountIn) private returns (uint256 used) {
        ISwapRouter.ExactInputSingleParams memory p = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: FEE,
            recipient: trader,
            deadline: block.timestamp + 60,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.prank(trader);
        uint256 g = gasleft();
        ISwapRouter(ROUTER).exactInputSingle(p);
        used = g - gasleft();
    }

    function test_gas_v3_swap() public {
        deal(USDC, trader, 10_000_000e6);
        vm.prank(trader);
        IERC20(USDC).approve(ROUTER, type(uint256).max);

        emit log_named_uint("v3 swap, $1k USDC->WETH, cold (first on the fork) ", _swap(1_000e6));
        emit log_named_uint("v3 swap, $1k USDC->WETH, warm (second)            ", _swap(1_000e6));
        emit log_named_uint("v3 swap, $100k, likely crosses ticks              ", _swap(100_000e6));
        emit log_named_uint("v3 swap, $1m, crosses more                        ", _swap(1_000_000e6));
    }

    function test_gas_v3_mint() public {
        (, int24 tick,,,,,) = IV3Pool(pool).slot0();
        int24 spacing = 10;
        // a range straddling the current tick, aligned to spacing
        int24 lower = (tick / spacing) * spacing - spacing * 50;
        int24 upper = (tick / spacing) * spacing + spacing * 50;

        deal(USDC, trader, 1_000_000e6);
        deal(WETH, trader, 1_000e18);
        vm.startPrank(trader);
        IERC20(USDC).approve(NFPM, type(uint256).max);
        IERC20(WETH).approve(NFPM, type(uint256).max);

        INFPM.MintParams memory p = INFPM.MintParams({
            token0: USDC,
            token1: WETH,
            fee: FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: 100_000e6,
            amount1Desired: 30e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: trader,
            deadline: block.timestamp + 60
        });
        uint256 g = gasleft();
        INFPM(NFPM).mint(p);
        uint256 used = g - gasleft();
        vm.stopPrank();

        emit log_named_int("current tick                                      ", tick);
        emit log_named_uint("v3 mint, new position, 100 spacings wide           ", used);
    }
}
