// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@uniswapV3/contracts/interfaces/IUniswapV3Pool.sol";

import "./PriceFeedL1.sol";
import "./LiquidityPoolFactory.sol";

contract Positions is ERC721, Ownable, ReentrancyGuard {
    // Structs and Enums
    enum positionState {
        OPEN,
        CLOSED_WITH_LIMIT_ORDER,
        CLOSED_WITH_STOP_LOSS,
        CLOSED_BY_LIQUIDATOR,
        CLOSED_BY_OWNER
    }

    struct PositionParams {
        IUniswapV3Pool v3Pool; // pool to trade
        ERC20 baseToken; // token to trade => should be token0 or token1 of v3Pool
        ERC20 quoteToken; // token to trade => should be the other token of v3Pool
        uint256 amount; // amount of token to trade
        uint256 initialPrice; // price of the token when the position was opened
        uint64 timestamp; // timestamp of position creation
        bool isShort; // true if short, false if long
        uint8 leverage; // leverage of position => 0 if no leverage
        uint256 totalBorrow; // Total borrow in baseToken if long or quoteToken if short
        uint256 hourlyFees; // fees to pay every hour on the borrowed amount => 0 if no leverage
        uint256 breakEvenLimit; // After this limit the posiiton is undercollateralize => 0 if no leverage or short
        uint256 limitPrice; // limit order price => 0 if no limit order
        uint256 stopLossPrice; // stop loss price => 0 if no stop loss
        positionState status; // status of the position
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

    string private constant BASE_SVG =
        "<svg xmlns='http://www.w3.org/2000/svg' preserveAspectRatio='xMinYMin meet' viewBox='0 0 350 350'><style>.base { fill: white; font-family: serif; font-size: 24px; }</style><rect width='100%' height='100%' fill='black' /><text x='50%' y='50%' class='base' dominant-baseline='middle' text-anchor='middle'>";

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
        if (ownerOf(_posId) == address(0)) {
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

    function tokenURI(
        uint256 _tokenId
    ) public view virtual override returns (string memory) {
        if (_tokenId >= posId) {
            revert Positions__POSITION_NOT_OPEN(_tokenId);
        }

        string memory json = Base64.encode(
            bytes(
                string.concat(
                    tokenURIIntro(_tokenId),
                    tokenURIAttributes(openPositions[_tokenId])
                )
            )
        );

        return string.concat("data:application/json;base64,", json);
    }

    function tokenURIIntro(
        uint256 _tokenId
    ) private pure returns (string memory) {
        return
            string.concat(
                '{"name": "Uniswap-Max Position #',
                Strings.toString(_tokenId),
                '", "description": "This NFT represent a position on Uniswap-Max. The owner can close or edit the position.", "image": "',
                imageURI(_tokenId)
            );
    }

    function tokenURIAttributes(
        PositionParams memory _position
    ) private view returns (string memory) {
        string[2] memory parts = [
            // To avoid stack too deep error
            string.concat(
                '", "attributes": [ { "trait_type": "Token", "value": "',
                _position.baseToken.name(), //? maybe write the quote token too
                '"}, { "trait_type": "Amount", "value": "',
                Strings.toString(_position.amount),
                '"} , { "trait_type": "Direction", "value": "',
                _position.isShort ? "Short" : "Long",
                '"}, { "trait_type": "Leverage", "value": "',
                Strings.toString(_position.leverage)
            ),
            string.concat(
                '"}, { "trait_type": "Limit Price", "value": "',
                Strings.toString(_position.limitPrice),
                '"}, { "trait_type": "Stop Loss Price", "value": "',
                Strings.toString(_position.stopLossPrice),
                '"}, { "trait_type": "Status", "value": "',
                _position.status == positionState.OPEN
                    ? "Open"
                    : _position.status == positionState.CLOSED_BY_OWNER // TODO : check different status
                    ? "Closed"
                    : "Liquidated",
                '"}]}'
            )
        ];

        return string.concat(parts[0], parts[1]);
    }

    function imageURI(uint256 _tokenId) private pure returns (string memory) {
        string memory svg = string.concat(
            BASE_SVG,
            "UNISWAP-MAX #",
            Strings.toString(_tokenId),
            "</text></svg>"
        );

        return
            string.concat(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(svg))
            );
    }

    // --------------- Trader Zone ---------------
    function openPosition(
        address _trader,
        address _v3Pool,
        address _token,
        bool _isShort,
        uint8 _leverage,
        uint256 _amount,
        uint256 _limitPrice,
        uint256 _stopLossPrice
    ) external onlyOwner /* nonReentrant */ returns (uint256) {
        // transfer funds to the contract (trader need to approve first)
        IERC20(_token).transferFrom(_trader, address(this), _amount);

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
            _totalBorrow = _amount * _leverage; // Borrow quoteToken
        } else {
            _totalBorrow = _amount * (_leverage - 1) * price; // Borrow baseToken
            _breakEvenLimit = price - (price * (10000 / _leverage)) / 10000;
        }

        if (_isShort || _leverage != 1) {
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

        // do the trade on Uniswap
        if (_isShort) {
            if (_leverage != 1) {
                // TODO : borrow, take fees, send reward to LP, do the trade
            } else {
                // TODO : do the trade
            }
            if (_limitPrice != 0) {
                // TODO : do the limit order
            }
        } else {
            if (_leverage != 1) {
                // TODO : borrow, take fees, send reward to LP, do the trade
            } else {
                // TODO : do the trade
            }
            if (_limitPrice != 0) {
                // TODO : do the limit order
            }
        }

        openPositions[posId + 1] = PositionParams(
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
            positionState.OPEN
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
        PositionParams memory posParms = openPositions[_posId];
        uint256 price = PriceFeedL1(priceFeed).getLatestPrice(
            address(posParms.baseToken),
            address(posParms.quoteToken)
        );

        // check the position state

        uint256 borrowFees = (posParms.totalBorrow * BORROW_FEE) / 10000;

        // Close position
        if (posParms.limitPrice != 0) {
            // TODO : close the limit order
        }
        if (posParms.isShort || posParms.leverage != 1) {
            // TODO : close the position
        } else {
            ERC20(posParms.baseToken).transfer(_trader, posParms.amount);
        }

        // refund LiquidityPool + Fees

        safeBurn(_posId);
        delete openPositions[_posId];
    }

    // function getTraderPositions(
    //     address _traderAdd
    // ) external view returns (uint256[] memory) {
    //     uint256[] memory _traderPositions = new uint256[](
    //         balanceOf(_traderAdd)
    //     );
    //     uint256 _posId = 0;

    //     for (uint256 i = 0; i < posId; ) {
    //         if (ownerOf(i) == _traderAdd) {
    //             _traderPositions[_posId] = i;

    //             unchecked {
    //                 ++_posId;
    //             }
    //         }

    //         unchecked {
    //             ++i;
    //         }
    //     }

    //     return _traderPositions;
    // }

    // function editPosition(
    //     address _trader,
    //     uint256 _posId,
    //     uint256 _newLimitPrice,
    //     uint256 _newLstopLossPrice
    // ) external onlyOwner {
    //     // TODO : check access control

    //     openPositions[_posId].limitPrice = _newLimitPrice;
    //     openPositions[_posId].stopLossPrice = _newLstopLossPrice;
    // }

    // // --------------- Liquidator Zone ---------------

    // function liquidatePosition(uint256 _posId) external {
    //     // TODO : check if liquidable
    //     // TODO : send liquidation reward

    //     safeBurn(_posId);
    //     delete openPositions[_posId];
    // }

    // function isLiquidable(uint256 _posId) public view returns (bool) {
    //     // TODO
    // }

    // function getLiquidablePositions() external view returns (uint256[] memory) {
    //     uint256[] memory _liquidablePositions = new uint256[](posId);
    //     uint256 _posId = 0;
    //     for (uint256 i = 0; i < posId; ) {
    //         if (isLiquidable(i)) {
    //             _liquidablePositions[_posId] = i;

    //             unchecked {
    //                 ++_posId;
    //             }
    //         }

    //         unchecked {
    //             ++i;
    //         }
    //     }

    //     assembly {
    //         mstore(
    //             _liquidablePositions,
    //             sub(mload(_liquidablePositions), sub(sload(posId.slot), _posId))
    //         )
    //     }

    //     return _liquidablePositions;
    // }
}
