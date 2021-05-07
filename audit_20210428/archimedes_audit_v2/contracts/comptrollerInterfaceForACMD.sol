pragma solidity ^0.6.12;

interface comptrollerInterfaceForACMD{

    function getBorrowSpeed(address cToken) external view returns (uint);

}

interface cTokenInterface{

    function totalBorrows() external returns (uint);

    function borrowBalanceStored(address account) external view returns (uint);

    function underlying() external view returns (address);
}