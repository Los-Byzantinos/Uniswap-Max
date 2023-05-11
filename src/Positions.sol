// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@solmate/tokens/ERC20.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@uniswapV3/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswapV3/contracts/libraries/TickMath.sol";
import "./PriceFeedL1.sol";
import "./LiquidityPoolFactory.sol";

contract Positions is ERC721, Ownable {
    // Structs
    struct PositionParams {
        IUniswapV3Pool v3Pool; // pool to trade
        ERC20 baseToken; // token to trade => should be token0 or token1 of v3Pool
        ERC20 quoteToken; // token to trade => should be the other token of v3Pool
        uint128 amount; // amount of token to trade
        uint256 initialPrice; // price of the token when the position was opened
        uint64 timestamp; // timestamp of position creation
        bool isShort; // true if short, false if long
        uint8 leverage; // leverage of position => 0 if no leverage
        uint256 totalBorrow; // Total borrow in baseToken if long or quoteToken if short
        uint256 hourlyFees; // fees to pay every hour on the borrowed amount => 0 if no leverage
        uint256 breakEvenLimit; // After this limit the position is undercollateralize => 0 if no leverage or short
        uint160 limitPrice; // limit order price => 0 if no limit order
        uint256 stopLossPrice; // stop loss price => 0 if no stop loss
        int24 tickLower; // tick lower of the range => 0 if no range
        int24 tickUpper; // tick upper of the range => 0 if no range
    }

    // Variables
    uint256 public constant LIQUIDATION_THRESHOLD = 1000; // 10% of margin
    uint256 public constant MIN_POSITION_AMOUNT_IN_USD = 100; // To avoid DOS attack
    uint256 public constant MAX_LEVERAGE = 5;
    uint256 public constant BORROW_FEE = 20; // 0.2% when opening a position
    uint256 public constant BORROW_FEE_EVERY_HOURS = 1; // 0.01% : assets borrowed/total assets in pool * 0.01%

    LiquidityPoolFactory public immutable liquidityPoolFactory;
    PriceFeedL1 public immutable priceFeed;
    address public immutable liquidityPoolFactoryUniswapV3;

    uint256 public posId;
    mapping(uint256 => PositionParams) public openPositions;

    string private constant BASE_SVG = "<svg xmlns='http://www.w3.org/2000/svg' preserveAspectRatio='xMinYMin meet' viewBox='0 0 350 350'><style>.base { fill: white; font-family: serif; font-size: 24px; }</style><rect width='100%' height='100%' fill='black' /><text x='50%' y='50%' class='base' dominant-baseline='middle' text-anchor='middle'>";

    // Errors
    error Positions__POSITION_NOT_OPEN(uint256 _posId);
    error Positions__POSITION_NOT_OWNED(address _trader, uint256 _posId);
    error Positions__POOL_NOT_OFFICIAL(address _v3Pool);
    error Positions__TOKEN_NOT_SUPPORTED(address _token);
    error Positions__TOKEN_NOT_SUPPORTED_ON_MARGIN(address _token);
    error Positions__NO_PRICE_FEED(address _token0, address _token1);
    error Positions__LEVERAGE_NOT_IN_RANGE(uint8 _leverage);
    error Positions__AMOUNT_TO_SMALL(uint256 _amount);
    error Positions__LIMIT_ORDER_PRICE_NOT_CONCISTENT(
        uint256 _limitPrice,
        uint256 _amount
    );
    error Positions__STOP_LOSS_ORDER_PRICE_NOT_CONCISTENT(
        uint256 _stopLossPrice,
        uint256 _amount
    );
    error Positions__NOT_LIQUIDABLE(uint256 _posId);

    constructor(
        address _market,
        address _priceFeed,
        address _liquidityPoolFactory,
        address _liquidityPoolFactoryUniswapV3
    ) ERC721("Uniswap-MAX", "UNIMAX") {
        transferOwnership(_market);
        liquidityPoolFactoryUniswapV3 = _liquidityPoolFactoryUniswapV3;
        liquidityPoolFactory = LiquidityPoolFactory(_liquidityPoolFactory);
        priceFeed = PriceFeedL1(_priceFeed);
    }

    modifier isPositionOpen(uint256 _posId) {
        if (_exists(_posId)) {
            revert Positions__POSITION_NOT_OPEN(_posId);
        }
        _;
    }

    modifier isPositionOwned(address _trader, uint256 _posId) {
        if (ownerOf(_posId) != _trader) {
            revert Positions__POSITION_NOT_OWNED(_trader, _posId);
        }
        _;
    }

    // --------------- ERC721 Zone ---------------

    function safeMint(address to) private returns (uint256) {
        uint256 _posId = posId;
        ++posId;
        _safeMint(to, _posId);
        return _posId;
    }

    function safeBurn(uint256 _posId) private {
        _burn(_posId);
    }

    function tokenURI(uint256 _tokenId) public view virtual override isPositionOpen(_tokenId) returns (string memory) {
        string memory json = Base64.encode(
            bytes(
            string.concat(tokenURIIntro(_tokenId),
                tokenURIAttributes(openPositions[_tokenId])
            ))
        );

        return string.concat('data:application/json;base64,', json);
    }

    function tokenURIIntro(uint256 _tokenId) private pure returns (string memory) {
        return
            string.concat(
                '{"name": "Uniswap-Max Position #',
                Strings.toString(_tokenId),
                '", "description": "This NFT represent a position on Uniswap-Max. The owner can close or edit the position.", "image": "',
                imageURI(_tokenId)
        );
    }

    function tokenURIAttributes(PositionParams memory _position) private view returns (string memory) {
        string[2] memory parts = [   // To avoid stack too deep error
            string.concat(
                '", "attributes": [ { "trait_type": "Tokens", "value": "', _position.baseToken.name(), "/", _position.quoteToken.name(),
                    '"}, { "trait_type": "Amount", "value": "', Strings.toString(_position.amount),
                    '"} , { "trait_type": "Direction", "value": "', _position.isShort ? "Short" : "Long",
                    '"}, { "trait_type": "Leverage", "value": "', Strings.toString(_position.leverage)
            ),
            string.concat(
                '"}, { "trait_type": "Limit Price", "value": "', Strings.toString(_position.limitPrice),
                '"}, { "trait_type": "Stop Loss Price", "value": "', Strings.toString(_position.stopLossPrice),
                '"}]}'
            )
        ];

        return string.concat(parts[0], parts[1]);
    }

    function imageURI(uint256 _tokenId) private pure returns (string memory) {
        string memory svg = string.concat(BASE_SVG, "UNISWAP-MAX #", Strings.toString(_tokenId), '</text></svg>');
        
        return string.concat('data:image/svg+xml;base64,', Base64.encode(bytes(svg)));
    }

    // --------------- Trader Zone ---------------
    function openPosition(
        address _trader,
        address _v3Pool,
        address _token,
        bool _isShort,
        uint8 _leverage,
        uint128 _amount,
        uint160 _limitPrice,
        uint256 _stopLossPrice
    ) external onlyOwner returns (uint256) {
        // transfer funds to the contract (trader need to approve first)
        ERC20(_token).transferFrom(_trader, address(this), _amount);

        // Check params
        (
            uint256 price,
            address baseToken,
            address quoteToken
        ) = checkPositionParams(
                _v3Pool,
                _token,
                _isShort,
                _leverage,
                _amount,
                _limitPrice,
                _stopLossPrice
            );

        // Compute parameters
        uint256 _breakEvenLimit;
        uint256 _totalBorrow;
        uint256 hourlyFees;

        if (_isShort) {
            _breakEvenLimit = price + (price * (10000 / _leverage)) / 10000;
            _totalBorrow = _amount * (_leverage - 1); // Borrow quoteToken
        } else {
            _totalBorrow = _amount * (_leverage - 1) * price; // Borrow baseToken
            _breakEvenLimit = price - (price * (10000 / _leverage)) / 10000;
        }

        if (_isShort || _leverage != 1) {
            _totalBorrow += (_totalBorrow * BORROW_FEE) / 10000;

            address cacheLiquidityPoolToUse = LiquidityPoolFactory(
                liquidityPoolFactory
            ).getTokenToLiquidityPools(_isShort ? quoteToken : baseToken);

            // fees computation
            hourlyFees =
                ((_totalBorrow /
                    LiquidityPool(cacheLiquidityPoolToUse).rawTotalAsset()) *
                    BORROW_FEE_EVERY_HOURS) /
                10000;

            // Borrow funds from the pool
            LiquidityPool(cacheLiquidityPoolToUse).borrow(_totalBorrow);
        } else {
            hourlyFees = 0;
        }

        int24 _tickLower = TickMath.getTickAtSqrtRatio(_limitPrice);
        int24 _tickUpper = _tickLower + 1;      //TODO to refine

        // do the trade on Uniswap
        if (_isShort) {
            if (_leverage != 1) {
                // TODO : borrow, take fees, send reward to LP, do the trade
            } else {
                // TODO : do the trade
            }
            if (_limitPrice != 0) {
                // TODO : do the limit order
                IUniswapV3Pool(_v3Pool).mint(
                    address(this),
                    _tickLower,
                    _tickUpper,
                    _amount + uint128(_totalBorrow),
                    abi.encode()
                );
            }
        } else {
            if (_leverage != 1) {
                // TODO : borrow, take fees, send reward to LP, do the trade
            } else {
                // TODO : do the trade
               
            }
            if (_limitPrice != 0) {
                // TODO : do the limit order
                IUniswapV3Pool(_v3Pool).mint(
                    address(this),
                    _tickLower,
                    _tickUpper,
                    _amount + uint128(_totalBorrow),
                    abi.encode()
                );
            }
        }

        openPositions[posId] = PositionParams(
            IUniswapV3Pool(_v3Pool),
            ERC20(baseToken),
            ERC20(quoteToken),
            _amount,
            price,
            uint64(block.timestamp),
            _isShort,
            _leverage,
            _totalBorrow,
            hourlyFees,
            _breakEvenLimit,
            _limitPrice,
            _stopLossPrice,
            _tickLower,
            _tickUpper
        );

        return safeMint(_trader);
    }

    function checkPositionParams(
        address _v3Pool,
        address _token,
        bool _isShort,
        uint8 _leverage,
        uint256 _amount,
        uint256 _limitPrice,
        uint256 _stopLossPrice
    ) private view returns (uint256, address, address) {
        address baseToken = _token;

        if (
            IUniswapV3Pool(_v3Pool).factory() != liquidityPoolFactoryUniswapV3
        ) {
            revert Positions__POOL_NOT_OFFICIAL(_v3Pool);
        }
        // check token
        if (
            IUniswapV3Pool(_v3Pool).token0() != baseToken &&
            IUniswapV3Pool(_v3Pool).token1() != baseToken
        ) {
            revert Positions__TOKEN_NOT_SUPPORTED(baseToken);
        }
        address quoteToken = (baseToken == IUniswapV3Pool(_v3Pool).token0())
            ? IUniswapV3Pool(_v3Pool).token1()
            : IUniswapV3Pool(_v3Pool).token0();

        // check if pair is supported by PriceFeed
        if (!PriceFeedL1(priceFeed).isPairSupported(baseToken, quoteToken)) {
            revert Positions__NO_PRICE_FEED(baseToken, quoteToken);
        }

        uint256 price = PriceFeedL1(priceFeed).getLatestPrice(
            baseToken,
            quoteToken
        );

        // check leverage
        if (_leverage < 1 || _leverage > MAX_LEVERAGE) {
            revert Positions__LEVERAGE_NOT_IN_RANGE(_leverage);
        }
        // when margin position check if token is supported by a LiquidityPool
        if (_leverage != 1) {
            if (
                _isShort &&
                LiquidityPoolFactory(liquidityPoolFactory)
                    .getTokenToLiquidityPools(baseToken) ==
                address(0)
            ) {
                revert Positions__TOKEN_NOT_SUPPORTED_ON_MARGIN(quoteToken);
            }
            if (
                !_isShort &&
                LiquidityPoolFactory(liquidityPoolFactory)
                    .getTokenToLiquidityPools(quoteToken) ==
                address(0)
            ) {
                revert Positions__TOKEN_NOT_SUPPORTED_ON_MARGIN(quoteToken);
            }
        }

        // check amount
        if (_amount < MIN_POSITION_AMOUNT_IN_USD) {
            revert Positions__AMOUNT_TO_SMALL(_amount);
        }
        if (_isShort) {
            if (_limitPrice > price) {
                revert Positions__LIMIT_ORDER_PRICE_NOT_CONCISTENT(
                    _limitPrice,
                    _amount
                );
            }
            if (_stopLossPrice < price) {
                revert Positions__STOP_LOSS_ORDER_PRICE_NOT_CONCISTENT(
                    _stopLossPrice,
                    _amount
                );
            }
        } else {
            if (_limitPrice < price) {
                revert Positions__LIMIT_ORDER_PRICE_NOT_CONCISTENT(
                    _limitPrice,
                    _amount
                );
            }
            if (_stopLossPrice > price) {
                revert Positions__STOP_LOSS_ORDER_PRICE_NOT_CONCISTENT(
                    _stopLossPrice,
                    _amount
                );
            }
        }
        return (price, baseToken, quoteToken);
    }

    function closePosition(
        address _trader,
        uint256 _posId
    ) external onlyOwner isPositionOwned(_trader, _posId) {
        _closePosition(_trader, _posId);
    }

    function _closePosition(
        address _trader,
        uint256 _posId
    ) internal {
        PositionParams memory posParms = openPositions[_posId];

        // check the position state

        uint256 borrowFees = (posParms.totalBorrow * BORROW_FEE) / 10000;

        // Close position
        if (posParms.limitPrice != 0) {
            // TODO : close the limit order
            (uint256 amount0, uint256 amount1) = posParms.v3Pool.burn(
                posParms.tickLower,
                posParms.tickUpper,
                posParms.amount + uint128(posParms.totalBorrow)
            );

            if (address(posParms.quoteToken) == posParms.v3Pool.token1() && amount0 != 0) {
                posParms.v3Pool.swap(
                    address(this),
                    false,
                    int256(amount0),
                    0,  //TODO define slippage here
                    abi.encode()
                );
            }

            if (address(posParms.quoteToken) == posParms.v3Pool.token0() && amount1 != 0) {
                posParms.v3Pool.swap(
                    address(this),
                    true,
                    int256(amount1),
                    0,  //TODO define slippage here
                    abi.encode()
                );
            }

            posParms.quoteToken.transfer(_trader, address(posParms.quoteToken) == posParms.v3Pool.token0() ? amount0 : amount1);
        }
        if (posParms.isShort || posParms.leverage != 1) {
            // TODO : close the position
        } else {
            posParms.baseToken.transfer(_trader, posParms.amount);
        }

        // refund LiquidityPool + Fees

        safeBurn(_posId);
        delete openPositions[_posId];
    }

    function getTraderPositions(
        address _traderAdd
    ) external view returns (uint256[] memory) {
        uint256[] memory _traderPositions = new uint256[](
            balanceOf(_traderAdd)
        );
        uint256 _posId = 0;

        for (uint256 i = 0; i < posId; ) {
            if (ownerOf(i) == _traderAdd) {
                _traderPositions[_posId] = i;

                unchecked {
                    ++_posId;
                }
            }

            unchecked {
                ++i;
            }
        }

        return _traderPositions;
    }

    function editPosition(
        address _trader,
        uint256 _posId,
        uint160 _newLimitPrice,
        uint256 _newLstopLossPrice
    ) external onlyOwner isPositionOwned(_trader, _posId) {
        PositionParams memory posParms = openPositions[_posId];
        checkPositionParams(
            address(posParms.v3Pool), 
            address(posParms.baseToken), 
            posParms.isShort,
            posParms.leverage, 
            posParms.amount,
            _newLimitPrice, 
            _newLstopLossPrice
        );
        openPositions[_posId].limitPrice = _newLimitPrice;
        openPositions[_posId].stopLossPrice = _newLstopLossPrice;
    }

    // --------------- Liquidator Zone ---------------

    function liquidatePosition(address _liquidator, uint256 _posId) external onlyOwner isPositionOpen(_posId) {
        if (!isLiquidable(_posId)) {
            revert Positions__NOT_LIQUIDABLE(_posId);
        }

        _closePosition(ownerOf(_posId), _posId);

        // TODO send reward to liquidator
        PositionParams memory posParms = openPositions[_posId];
        uint256 _price = PriceFeedL1(priceFeed).getLatestPrice(
            address(posParms.baseToken),
            address(posParms.quoteToken)
        );

        uint256 _breakEventPrice = (posParms.breakEvenLimit ** 2) / (2 ** 192);
        
        uint256 _reward;
        if (posParms.isShort) {
            if (_price > _breakEventPrice) {
                _reward = 0;    // TODO define reward in the case of a loss for the protocol
            } else {
                _reward = _breakEventPrice / _price * posParms.amount;
            }
        } else {
            if (_price < _breakEventPrice) {
                _reward = 0;    // TODO define reward in the case of a loss for the protocol
            } else {
                _reward = _breakEventPrice / _price * posParms.amount;
            }
        }

        posParms.quoteToken.transfer(_liquidator, _reward);

        if (_reward < posParms.amount) {
            posParms.quoteToken.transfer(ownerOf(_posId), posParms.amount - _reward);
        }
    }

    function isLiquidable(uint256 _posId) public view returns (bool) {
        PositionParams memory posParms = openPositions[_posId];
        uint256 _price = PriceFeedL1(priceFeed).getLatestPrice(
            address(posParms.baseToken),
            address(posParms.quoteToken)
        );

        // liquidable because of stop loss
        uint256 _thresholdStopLoss = (posParms.stopLossPrice * LIQUIDATION_THRESHOLD) / 10000;
        if (posParms.isShort) {
            if (_price > posParms.stopLossPrice + _thresholdStopLoss) {
                return true;
            }
        } else {
            if (_price < posParms.stopLossPrice - _thresholdStopLoss) {
                return true;
            }
        }

        // liquidable because of take profit
        if (posParms.isShort) {
            if (_price < posParms.limitPrice) {
                return true;
            }
        } else {
            if (_price > posParms.limitPrice) {
                return true;
            }
        }

        return false;
    }

    function getLiquidablePositions() external view returns (uint256[] memory) {
        uint256[] memory _liquidablePositions = new uint256[](posId);
        uint256 _posId = 0;
        for (uint256 i = 0; i < posId; ) {
            if (isLiquidable(i)) {
                _liquidablePositions[_posId] = i;

                unchecked {
                    ++_posId;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            let tosub := sub(sload(posId.slot), _posId)
            mstore(
                _liquidablePositions,
                sub(mload(_liquidablePositions), tosub)
            )
        }

        return _liquidablePositions;
    }
}
