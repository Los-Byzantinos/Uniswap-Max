// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./interfaces/IMarket.sol";
import "./Positions.sol";
import "./LiquidityPool.sol";
import "./LiquidityPoolFactory.sol";

contract Market is IMarket {
    Positions private positions;
    LiquidityPoolFactory private liquidityPoolFactory;

    constructor(address _positions, address _liquidityPoolFactory) {
        positions = Positions(_positions);
        liquidityPoolFactory = LiquidityPoolFactory(_liquidityPoolFactory);
    }

    // --------------- Trader Zone ---------------
    function openPosition(
        address _v3Pool,
        address _token,
        bool _isShort,
        uint8 _leverage,
        uint256 _value,
        uint256 _limitPrice,
        uint256 _stopLossPrice
    ) external {
        uint256 posId = positions.openPosition(
            msg.sender,
            _v3Pool,
            _token,
            _isShort,
            _leverage,
            _value,
            _limitPrice,
            _stopLossPrice
        );
        emit PositionOpened(
            posId,
            msg.sender,
            _v3Pool,
            _token,
            _value,
            _isShort,
            _leverage,
            _limitPrice,
            _stopLossPrice
        );
    }

    function closePosition(uint256 _posId) external {
        positions.closePosition(_posId, msg.sender);
        emit PositionClosed(_posId, msg.sender);
    }

    function editPosition(
        uint256 _posId,
        uint256 _newLimitPrice,
        uint256 _newLstopLossPrice
    ) external {
        positions.editPosition(_posId, _newLimitPrice, _newLstopLossPrice);
        emit PositionEdited(
            _posId,
            msg.sender,
            _newLimitPrice,
            _newLstopLossPrice
        );
    }

    function getTraderPositions(
        address _traderAdd
    ) external view returns (uint256[] memory) {
        return positions.getTraderPositions(_traderAdd);
    }

    // --------------- Liquidity Provider Zone ---------------
    /** @notice provide a simple interface to deal with pools.
     *          Of course a user can interact directly with the
     *          pool contract if he wants through deposit/withdraw
     *          and mint/redeem functions
     */
    function addLiquidity(address _poolAdd, uint256 _assets) external {
        LiquidityPool(_poolAdd).deposit(_assets, msg.sender);
        emit LiquidityAdded(_poolAdd, msg.sender, _assets);
    }

    function removeLiquidity(address _poolAdd, uint256 _shares) external {
        LiquidityPool(_poolAdd).redeem(_shares, msg.sender, msg.sender);
        emit LiquidityRemoved(_poolAdd, msg.sender, _shares);
    }

    // --------------- Liquidator/Keeper Zone ----------------
    function liquidatePositions(uint256[] memory _posIds) external {
        uint256 len = _posIds.length;

        for (uint256 i; i < len; ++i) {
            // Is that safe ?
            try positions.liquidatePosition(_posIds[i]) {
                emit PositionLiquidated(_posIds[i], msg.sender);
            } catch {}
        }
    }

    function getLiquidablePositions() external view returns (uint256[] memory) {
        return positions.getLiquidablePositions();
    }

    // --------------- Admin Zone ---------------
    function createLiquidityPool(address _token) external {
        liquidityPoolFactory.createLiquidityPool(_token);
        emit LiquidityPoolCreated(_token, msg.sender);
    }
}
