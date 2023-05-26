// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@solmate/tokens/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LiquidityPool.sol";

// Errors
error LiquidityPoolFactory__POOL_ALREADY_EXIST(address pool);

contract LiquidityPoolFactory is Ownable {
    address public immutable market;
    address public immutable positions;

    mapping(address => address) private tokenToLiquidityPools;

    constructor(address _positions, address _market) {
        market = _market;
        positions = _positions;
        transferOwnership(_market);
    }

    /**
     * @notice function to create a new liquidity from
     * @param _asset address of the ERC20 token
     * @return address of the new liquidity pool
     */
    function createLiquidityPool(address _asset) external onlyOwner returns (address) {
        address cachedLiquidityPools = tokenToLiquidityPools[_asset];

        if (cachedLiquidityPools != address(0))
            revert LiquidityPoolFactory__POOL_ALREADY_EXIST(cachedLiquidityPools);

        address _liquidityPool = address(new LiquidityPool(ERC20(_asset), positions));

        tokenToLiquidityPools[_asset] = _liquidityPool;
        return _liquidityPool;
    }

    function getTokenToLiquidityPools(address _token) external view returns (address) {
        return tokenToLiquidityPools[_token];
    }
}
