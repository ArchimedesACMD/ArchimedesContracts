// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;


import '../Governable.sol';
import '../IBaseOracle.sol';
import '../IERC20_extended.sol';
import '../SafeMath.sol';

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// Ref: https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint);

    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
    external
    view
    returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast
    );

    function price0CumulativeLast() external view returns (uint);

    function price1CumulativeLast() external view returns (uint);

    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);

    function burn(address to) external returns (uint amount0, uint amount1);

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}


contract PriceOracleProxy_full is IBaseOracle, Governable {
    using SafeMath for uint;
    
    /// @notice Admin address
    address public admin;

    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /// @notice Chainlink Aggregators
    mapping(address => AggregatorV3Interface) public aggregators;

    /// @notice Check if the underlying address is Uniswap or SushiSwap LP
    mapping(address => bool) public areLPs;

    mapping(address => bool) public areCTokens;
    mapping(address => address) public Underlyings;


    /**
     * @param admin_ The address of admin to set aggregators
     */
    constructor(address admin_) public {
        admin = admin_;
    }

    function getUSDPx(address token) external view override returns (uint) {
        if (areLPs[token])  {
            return getLPFairPrice(token);
        } else if (areCTokens[token]) {
            return getUnderlyingPrice(token);
        } else {
            return getTokenPrice(token);
        }
    }

    /**
     * @notice Get the price of a specific token.
     * @param token The token to get the price of
     * @return The price
     */
    function getTokenPrice(address token) internal view returns (uint) {

        AggregatorV3Interface aggregator = aggregators[token];
        if (address(aggregator) != address(0)) {
            uint price = getPriceFromChainlink(aggregator);
            //uint underlyingDecimals = IERC20_extended(token).decimals();
            return price;                    
        }
        return 0;             //不支持的资产返回0
    }

    function getUnderlyingPrice(address CToken) public view returns (uint) {
        if (Underlyings[CToken] == 0x0298c2b32eaE4da002a15f36fdf7615BEa3DA047) {
            return getTokenPrice(Underlyings[CToken]).mul(1e10);        //HUSD
        } else {
            return getTokenPrice(Underlyings[CToken]);
        }
    }

    /**
     * @notice Get price from ChainLink
     * @param aggregator The ChainLink aggregator to get the price of
     * @return The price
     */
    function getPriceFromChainlink(AggregatorV3Interface aggregator) internal view returns (uint) {
        ( , int price, , , ) = aggregator.latestRoundData();
        require(price > 0, "invalid price");

        // Extend the decimals to 1e18.
        return uint(price).mul( 10**(18 - uint(aggregator.decimals())));           //拿到的价格是美元*1e18后的
    }

    /**
     * @notice Get the fair price of a LP. We use the mechanism from Alpha Finance.
     *         Ref: https://blog.alphafinance.io/fair-lp-token-pricing/
     * @param pair The pair of AMM (Uniswap or SushiSwap)
     * @return The price
     */
    function getLPFairPrice(address pair) internal view returns (uint) {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        if (token0 == 0x0298c2b32eaE4da002a15f36fdf7615BEa3DA047 || token1 == 0x0298c2b32eaE4da002a15f36fdf7615BEa3DA047) {
            uint totalSupply = IUniswapV2Pair(pair).totalSupply();
            (uint r0, uint r1, ) = IUniswapV2Pair(pair).getReserves();
            uint sqrtR = sqrt(r0.mul(r1));
            uint p0 = getTokenPrice(token0);
            uint p1 = getTokenPrice(token1);
            uint sqrtP = sqrt(p0.mul(p1));
            return uint(2).mul(sqrtR).mul(sqrtP).div(totalSupply).mul(1e5);
        } else {
            uint totalSupply = IUniswapV2Pair(pair).totalSupply();
            (uint r0, uint r1, ) = IUniswapV2Pair(pair).getReserves();
            uint sqrtR = sqrt(r0.mul(r1));
            uint p0 = getTokenPrice(token0);
            uint p1 = getTokenPrice(token1);
            uint sqrtP = sqrt(p0.mul(p1));
            return uint(2).mul(sqrtR).mul(sqrtP).div(totalSupply);
        }
    }

    event AggregatorUpdated(address tokenAddress, address source);
    event IsLPUpdated(address tokenAddress, bool isLP);
    event IsCTokenUpdated(address tokenAddress, bool isCToken);

    function _setAggregators(address[] calldata tokenAddresses, address[] calldata sources) external {
        require(msg.sender == admin, "only the admin may set the aggregators");
        require(tokenAddresses.length == sources.length, "mismatched data");
        for (uint i = 0; i < tokenAddresses.length; i++) {
            aggregators[tokenAddresses[i]] = AggregatorV3Interface(sources[i]);
            emit AggregatorUpdated(tokenAddresses[i], sources[i]);
        }
    }

    function _setLPs(address[] calldata LPs, bool[] calldata isLP) external {
        require(msg.sender == admin, "only the admin may set LPs");
        require(LPs.length == isLP.length, "mismatched data");
        for (uint i = 0; i < LPs.length; i++) {
            areLPs[LPs[i]] = isLP[i];
            emit IsLPUpdated(LPs[i], isLP[i]);
        }
    }

    function _setCTokens(address[] calldata CTokens, bool[] calldata isCToken, address[] calldata underlyingTokens) external {
        require(msg.sender == admin, "only the admin may set CTokens");
        require(CTokens.length == isCToken.length, "mismatched data");
        require(CTokens.length == underlyingTokens.length, "mismatched data");
        for (uint i = 0; i < CTokens.length; i++) {
            areCTokens[CTokens[i]] = isCToken[i];
            Underlyings[CTokens[i]] = underlyingTokens[i];
            emit IsCTokenUpdated(CTokens[i], isCToken[i]);
        }
    }

    function _setAdmin(address _admin) external {
        require(msg.sender == admin, "only the admin may set new admin");
        admin = _admin;
    }

    function sqrt(uint x) pure internal returns (uint) {
        if (x == 0) return 0;
        uint xx = x;
        uint r = 1;

        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }

        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint r1 = x / r;
        return (r < r1 ? r : r1);
    }
}