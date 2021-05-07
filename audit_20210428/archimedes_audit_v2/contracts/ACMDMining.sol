pragma solidity ^0.6.12;

import './IERC20.sol';
import './SafeMath.sol';
import './SafeERC20.sol';
import './comptrollerInterfaceForACMD.sol';
import './IBank.sol';
import './Initializable.sol';

contract acmdMining is Initializable{
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public owner;

    IERC20 public rewardsToken;
    comptrollerInterfaceForACMD comptroller;
    IBank public archimedesBank;

    struct tokenInfo{
        uint rewardSpeed;
        uint lastUpdateBlockNumber;
        uint rewardPerShareStored;
    }

    /// @notice from token to tokenInfo
    mapping (address => tokenInfo) public TokenInfos;


    /// @notice from position to token to rewards
    mapping(uint => mapping(address => uint256)) public rewards;

    /// @notice from position to token to positionRewardPerSharePaid
    mapping(uint => mapping(address => uint256)) public positionRewardPerSharePaid;

    address[] public CTokens;

    bool private _mutex;

    uint public totalRewarded;

    /// @dev Reentrancy lock guard.
    modifier reentrancyLock() {
        require(!_mutex, "ERR_REENTRY");
        _mutex = true;
        _;
        _mutex = false;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        _;
    }

    function initialize (
        IERC20 _rewardsToken,
        IBank _archimedesBank,
        comptrollerInterfaceForACMD _comptroller,
        address _owner
    ) external initializer {
        rewardsToken = _rewardsToken;
        archimedesBank = _archimedesBank;
        comptroller = _comptroller;
        owner = _owner;

    }

    /// @notice add cTokens which participate in reward
    function addCTokens(address[] calldata cTokens) public onlyOwner {
        require(cTokens.length > 0, "empty cTokens");
        for (uint i = 0; i < cTokens.length; i++){
            CTokens.push(cTokens[i]);
            TokenInfos[cTokenInterface(cTokens[i]).underlying()].lastUpdateBlockNumber = block.number;
        }
        updateRewardSpeed();
    }

    /// @notice get rewarded by a batch of positions
    function rewardUserPositions(uint[] calldata position) external returns (uint){
        require(position.length > 0, "empty positions");
        require(position.length <= 30, "too much positions");
        uint totalReward;
        for (uint i = 0; i < position.length; i++){
            (address[] memory tokens, ) = IBank(archimedesBank).getPositionDebts(position[i]);
            for (uint j = 0; j < tokens.length; j++){
                totalReward = totalReward.add(getReward(position[i], tokens[j]));
            }
        }
        return totalReward;
    }

    /// @notice hooked in spell, triggered before adding and removing liquidity
    function rewardPosition(uint position, address tokenA, address tokenB) public returns (uint){
        uint rewardAmountOfPosition = getReward(position, tokenA).add(getReward(position, tokenB));
        updateRewardSpeed();
        return rewardAmountOfPosition;
    }

    /// @notice transfer the acmd reward of position in token to its owner
    /// @return the reward transfered
    function getReward(uint position, address token) reentrancyLock public returns (uint){
        (address account, , , ) = archimedesBank.getPositionInfo(position);
        require (account != address(0), "empty position");
        updateReward(position, token);
        uint256 reward = rewards[position][token];
        if (reward > 0) {
            rewards[position][token] = 0;
            rewardsToken.safeTransfer(account, reward);
            totalRewarded = totalRewarded.add(reward);
        }
        return reward;

    }

    /// @notice update user's reward in token
    function updateReward(uint position, address token) internal{
        TokenInfos[token].rewardPerShareStored = rewardPerShare(token);
        TokenInfos[token].lastUpdateBlockNumber = block.number;
        if (position != uint(-1)) {
            rewards[position][token] = earned(position,token);
            positionRewardPerSharePaid[position][token] = TokenInfos[token].rewardPerShareStored;
        }
    }

    /// @notice update reward speed of each token
    function updateRewardSpeed() public {
        for (uint i = 0; i < CTokens.length; i++){
            address cToken = CTokens[i];
            uint alphaBorrows = cTokenInterface(cToken).borrowBalanceStored(address(archimedesBank));
            uint cTokenBorrows = cTokenInterface(cToken).totalBorrows();
            uint cTokenBorrowSpeed = comptroller.getBorrowSpeed(address(cToken));
            if (cTokenBorrows > 0){
                TokenInfos[cTokenInterface(cToken).underlying()].rewardSpeed = cTokenBorrowSpeed.mul(alphaBorrows).div(cTokenBorrows);
            }
        }
    }

    /// @notice return reward per debt of token, scaled by 1e18
    function rewardPerShare(address token) public view returns (uint256) {
        tokenInfo memory Token = TokenInfos[token];
        ( , , , , uint _totalShare) = archimedesBank.getBankInfo(token);

        if (_totalShare == 0) {
            return Token.rewardPerShareStored;
        }
        return
        Token.rewardPerShareStored.add(
            block.number.sub(Token.lastUpdateBlockNumber).mul(Token.rewardSpeed).mul(1e18).div(_totalShare)
        );
    }

    /// @notice return the reward earned of position in token
    function earned(uint position, address token) public view returns (uint256) {
        uint _debtShare = archimedesBank.getPositionDebtShareOf(position, token);
        uint deltaRewardPerShare;
        if (rewardPerShare(token) > positionRewardPerSharePaid[position][token]) {
            deltaRewardPerShare = rewardPerShare(token).sub(positionRewardPerSharePaid[position][token]);
        }
        return _debtShare.mul(deltaRewardPerShare).div(1e18).add(rewards[position][token]);
    }

}