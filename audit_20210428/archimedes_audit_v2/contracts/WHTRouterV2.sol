pragma solidity 0.6.12;

import './SafeMath.sol';
import './IERC20.sol';
import './ArchimedesMath.sol';

interface WHTRouterV2WHTv2 is IERC20 {
  function deposit() external payable;

  function withdraw(uint amount) external;
}

interface WHTRouterV2MdxPair is IERC20 {
  function token0() external view returns (address);

  function getReserves()
    external
    view
    returns (
      uint,
      uint,
      uint
    );
}

interface WHTRouterV2MdxRouter {
  function factory() external view returns (address);

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  )
    external
    returns (
      uint amountA,
      uint amountB,
      uint liquidity
    );

  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB);

  function swapExactTokensForTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
  ) external returns (uint[] memory amounts);
}

interface WHTRouterV2MdxFactory {
  function getPair(address tokenA, address tokenB) external view returns (address);
}


contract WHTRouterV2 {
  using SafeMath for uint;

  IERC20 public immutable acmd;
  WHTRouterV2WHTv2 public immutable WHTv2;   
  WHTRouterV2MdxPair public immutable lpToken;
  WHTRouterV2MdxRouter public immutable router;

  constructor(
    IERC20 _acmd,    
    WHTRouterV2WHTv2 _WHTv2,  
    WHTRouterV2MdxRouter _router  
  ) public {
    WHTRouterV2MdxPair _lpToken =   
      WHTRouterV2MdxPair(
        WHTRouterV2MdxFactory(_router.factory()).getPair(address(_acmd), address(_WHTv2))
      );
    acmd = _acmd;
    WHTv2 = _WHTv2;
    lpToken = _lpToken;
    router = _router;
    require(_acmd.approve(address(_router), uint(-1)));
    require(_WHTv2.approve(address(_router), uint(-1)));
    require(_lpToken.approve(address(_router), uint(-1)));
  }

  function optimalDeposit(
    uint amtA,
    uint amtB,
    uint resA,
    uint resB
  ) internal pure returns (uint swapAmt, bool isReversed) {
    if (amtA.mul(resB) >= amtB.mul(resA)) {   //amtA/amtB>=resA/resB
      swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
      isReversed = false;
    } else {
      swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
      isReversed = true;
    }
  }

  function _optimalDepositA(  
    uint amtA,
    uint amtB,
    uint resA,
    uint resB
  ) internal pure returns (uint) {
    require(amtA.mul(resB) >= amtB.mul(resA), 'Reversed');
    uint a = 997;
    uint b = uint(1997).mul(resA);
    uint _c = (amtA.mul(resB)).sub(amtB.mul(resA));
    uint c = _c.mul(1000).div(amtB.add(resB)).mul(resA);
    uint d = a.mul(c).mul(4);
    uint e = ArchimedesMath.sqrt(b.mul(b).add(d));
    uint numerator = e.sub(b);
    uint denominator = a.mul(2);
    return numerator.div(denominator);
  }

  function swapExactHTToACMD(
    uint amountOutMin,
    address to,
    uint deadline
  ) external payable {
    WHTv2.deposit{value: msg.value}();
    address[] memory path = new address[](2);
    path[0] = address(WHTv2);
    path[1] = address(acmd);
    router.swapExactTokensForTokens(
      WHTv2.balanceOf(address(this)),
      amountOutMin,
      path,
      to,
      deadline
    );
  }

  function swapExactACMDToHT(
    uint amountIn,
    uint amountOutMin,
    address to,
    uint deadline
  ) external {
    acmd.transferFrom(msg.sender, address(this), amountIn);   
    address[] memory path = new address[](2);
    path[0] = address(acmd);
    path[1] = address(WHTv2);
    router.swapExactTokensForTokens(amountIn, 0, path, address(this), deadline);  
    WHTv2.withdraw(WHTv2.balanceOf(address(this)));   
    uint htBalance = address(this).balance; 
    require(htBalance >= amountOutMin, '!amountOutMin'); 
    (bool success, ) = to.call{value: htBalance}(new bytes(0)); 
    require(success, '!ht');
  }

  function addLiquidityHTACMDOptimal(
    uint amountACMD,
    uint minLp,
    address to,
    uint deadline
  ) external payable {
    if (amountACMD > 0) acmd.transferFrom(msg.sender, address(this), amountACMD);
    WHTv2.deposit{value: msg.value}();   
    uint amountWHTv2 = WHTv2.balanceOf(address(this));
    uint swapAmt;
    bool isReversed;
    {
      (uint r0, uint r1, ) = lpToken.getReserves();  
      (uint WHTv2Reserve, uint acmdReserve) =
        lpToken.token0() == address(WHTv2) ? (r0, r1) : (r1, r0);
      (swapAmt, isReversed) = optimalDeposit(  
        amountWHTv2,
        amountACMD,
        WHTv2Reserve,
        acmdReserve
      );
    }
    if (swapAmt > 0) {
      address[] memory path = new address[](2);
      (path[0], path[1]) = isReversed
        ? (address(acmd), address(WHTv2))
        : (address(WHTv2), address(acmd));
      router.swapExactTokensForTokens(swapAmt, 0, path, address(this), deadline);  
    }
    (, , uint liquidity) =    
      router.addLiquidity(
        address(acmd),
        address(WHTv2),
        acmd.balanceOf(address(this)),
        WHTv2.balanceOf(address(this)),
        0,
        0,
        to,
        deadline
      );
    require(liquidity >= minLp, '!minLP');   
  }

  function addLiquidityWHTv2ACMDOptimal(
    uint amountWHTv2,
    uint amountACMD,
    uint minLp,
    address to,
    uint deadline
  ) external {
    if (amountACMD > 0) acmd.transferFrom(msg.sender, address(this), amountACMD);
    if (amountWHTv2 > 0) WHTv2.transferFrom(msg.sender, address(this), amountWHTv2);
    uint swapAmt;
    bool isReversed;
    {
      (uint r0, uint r1, ) = lpToken.getReserves();
      (uint WHTv2Reserve, uint acmdReserve) =
        lpToken.token0() == address(WHTv2) ? (r0, r1) : (r1, r0);
      (swapAmt, isReversed) = optimalDeposit(
        amountWHTv2,
        amountACMD,
        WHTv2Reserve,
        acmdReserve
      );
    }
    if (swapAmt > 0) {
      address[] memory path = new address[](2);
      (path[0], path[1]) = isReversed
        ? (address(acmd), address(WHTv2))
        : (address(WHTv2), address(acmd));
      router.swapExactTokensForTokens(swapAmt, 0, path, address(this), deadline);
    }
    (, , uint liquidity) =
      router.addLiquidity(
        address(acmd),
        address(WHTv2),
        acmd.balanceOf(address(this)),
        WHTv2.balanceOf(address(this)),
        0,
        0,
        to,
        deadline
      );
    require(liquidity >= minLp, '!minLP');
  }

  function removeLiquidityHTACMD(
    uint liquidity,
    uint minHT,
    uint minACMD,
    address to,
    uint deadline
  ) external {
    lpToken.transferFrom(msg.sender, address(this), liquidity);  
    router.removeLiquidity(   
      address(acmd),
      address(WHTv2),
      liquidity,
      minACMD,
      0,
      address(this),
      deadline
    );
    acmd.transfer(msg.sender, acmd.balanceOf(address(this)));
    WHTv2.withdraw(WHTv2.balanceOf(address(this)));  
    uint htBalance = address(this).balance;
    require(htBalance >= minHT, '!minHT');
    (bool success, ) = to.call{value: htBalance}(new bytes(0));   
    require(success, '!ht');
  }
  
  function removeLiquidityWHTv2ACMD(
    uint liquidity,
    uint minWHTv2,
    uint minACMD,
    uint deadline
  ) external {
    lpToken.transferFrom(msg.sender, address(this), liquidity); 
    router.removeLiquidity(  
      address(acmd),
      address(WHTv2),
      liquidity,
      minACMD,
      0,
      address(this),
      deadline
    );
    require(acmd.balanceOf(address(this)) >= minACMD);
    require(WHTv2.balanceOf(address(this)) >= minWHTv2);
    acmd.transfer(msg.sender, acmd.balanceOf(address(this)));
    WHTv2.transfer(msg.sender, WHTv2.balanceOf(address(this)));
  }

  function removeLiquidityACMDOnly(
    uint liquidity,
    uint minACMD,
    address to,
    uint deadline
  ) external {
    lpToken.transferFrom(msg.sender, address(this), liquidity);
    router.removeLiquidity(
      address(acmd),
      address(WHTv2),
      liquidity,
      0,
      0,
      address(this),
      deadline
    );
    address[] memory path = new address[](2);
    path[0] = address(WHTv2);
    path[1] = address(acmd);
    router.swapExactTokensForTokens(
      WHTv2.balanceOf(address(this)),
      0,
      path,
      address(this),
      deadline
    );
    uint acmdBalance = acmd.balanceOf(address(this));
    require(acmdBalance >= minACMD, '!minACMD');
    acmd.transfer(to, acmdBalance);
  }

  receive() external payable {
    require(msg.sender == address(WHTv2), '!WHTv2');
  }
}
