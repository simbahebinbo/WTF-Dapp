// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./libraries/SafeCast.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/SwapMath.sol";
import "./libraries/FixedPoint128.sol";

import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";

contract Pool is IPool {
    using SafeCast for int256;
    using SafeCast for uint256;
    using LowGasSafeMath for int256;
    using LowGasSafeMath for uint256;
    using TickBitmap for mapping(int16 => uint256);

    /// @inheritdoc IPool
    address public immutable override factory;
    /// @inheritdoc IPool
    address public immutable override token0;
    /// @inheritdoc IPool
    address public immutable override token1;
    /// @inheritdoc IPool
    uint24 public immutable override fee;
    /// @inheritdoc IPool
    int24 public immutable override tickLower;
    /// @inheritdoc IPool
    int24 public immutable override tickUpper;

    /// @inheritdoc IPool
    uint160 public override sqrtPriceX96;
    /// @inheritdoc IPool
    int24 public override tick;
    /// @inheritdoc IPool
    uint128 public override liquidity;

    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal1X128;

    // 用一个 mapping 来存放所有 Position 的信息
    mapping(address => Position) public positions;

    constructor() {
        // constructor 中初始化 immutable 的常量
        // Factory 创建 Pool 时会通 new Pool{salt: salt}() 的方式创建 Pool 合约，通过 salt 指定 Pool 的地址，这样其他地方也可以推算出 Pool 的地址
        // 参数通过读取 Factory 合约的 parameters 获取
        // 不通过构造函数传入，因为 CREATE2 会根据 initcode 计算出新地址（new_address = hash(0xFF, sender, salt, bytecode)），带上参数就不能计算出稳定的地址了
        (factory, token0, token1, tickLower, tickUpper, fee) = IFactory(
            msg.sender
        ).parameters();
    }

    function initialize(uint160 sqrtPriceX96_) external override {
        // 初始化 Pool 的 sqrtPriceX96
        sqrtPriceX96 = sqrtPriceX96_;
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // any change in liquidity
        int128 liquidityDelta;
    }

    function _modifyPosition(
        ModifyPositionParams memory params
    ) private returns (int256 amount0, int256 amount1) {
        // 通过新增的流动性计算 amount0 和 amount1
        // 参考 UniswapV3 的代码
        amount0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickUpper),
            params.liquidityDelta
        );
        amount1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtRatioAtTick(tickLower),
            sqrtPriceX96,
            params.liquidityDelta
        );

        // 修改 liquidity
        uint128 liquidityBefore = liquidity;
        liquidity = LiquidityMath.addDelta(
            liquidityBefore,
            params.liquidityDelta
        );
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function mint(
        address recipient,
        uint128 amount,
        bytes calldata data
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Mint amount must be greater than 0");
        // 基于 amount 计算出当前需要多少 amount0 和 amount1
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                liquidityDelta: int256(int128(amount)).toInt128()
            })
        );
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);
        // 把流动性记录到对应的 position 中
        positions[recipient].liquidity += amount;

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        // 回调 mintCallback
        IMintCallback(recipient).mintCallback(amount0, amount1, data);

        if (amount0 > 0)
            require(balance0Before.add(amount0) <= balance0(), "M0");
        if (amount1 > 0)
            require(balance1Before.add(amount1) <= balance1(), "M1");

        emit Mint(msg.sender, recipient, amount, amount0, amount1);
    }

    function collect(
        address recipient
    ) external override returns (uint128 amount0, uint128 amount1) {
        // 获取当前用户的 position
        Position storage position = positions[msg.sender];
        // 把钱退给用户 recipient，只支持全部退还
        amount0 = position.tokensOwed0;
        amount1 = position.tokensOwed1;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, amount0, amount1);
    }

    function burn(
        uint128 amount
    ) external override returns (uint256 amount0, uint256 amount1) {
        // 修改 positions 中的信息
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                liquidityDelta: -int256(int128(amount)).toInt128()
            })
        );
        // 获取燃烧后的 amount0 和 amount1
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (
                positions[msg.sender].tokensOwed0,
                positions[msg.sender].tokensOwed1
            ) = (
                positions[msg.sender].tokensOwed0 + uint128(amount0),
                positions[msg.sender].tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, amount, amount0, amount1);
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // the current liquidity in range
        uint128 liquidity;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "AS");

        // zeroForOne: 如果从 token0 交换 token1 则为 true，从 token1 交换 token0 则为 false
        // 判断当前价格是否满足交易的条件
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "SPL"
        );

        // 临时存储交易状态
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            liquidity: liquidity
        });

        // amountSpecified 大于 0 代表用户指定了 token0 的数量，小于 0 代表用户指定了 token1 的数量
        bool exactInput = amountSpecified > 0;

        // TODO 这里计算交易
        // TODO state.sqrtPriceX96 交易后的价格
        // TODO state.amountCalculated 交易的 token 数量
        // TODO state.amountSpecifiedRemaining 没有完成的交易数量
        // TODO state.tick 交易后的 tick
        // TODO state.liquidity 交易后的流动性
        // TODO 累计手续费 feeGrowthGlobal0X128
        // TODO 累计手续费 feeGrowthGlobal1X128
        // TODO _modifyPosition 中也要考虑计算手续费

        // 更新新的价格
        sqrtPriceX96 = state.sqrtPriceX96;
        tick = state.tick;

        // 更新流动性
        liquidity = state.liquidity;

        // 计算交易后用户手里的 token0 和 token1 的数量
        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        // do the transfers and collect payment
        if (zeroForOne) {
            if (amount1 < 0)
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );

            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");
        } else {
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );

            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            state.sqrtPriceX96,
            state.liquidity,
            state.tick
        );
    }
}
