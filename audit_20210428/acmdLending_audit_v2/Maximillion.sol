pragma solidity ^0.5.16;

import "./aHT.sol";

/**
 * @title Acmd's Maximillion Contract
 * @author Acmd
 */
contract Maximillion {
    /**
     * @notice The default aHT market to repay in
     */
    aHT public aHT;

    /**
     * @notice Construct a Maximillion to repay max in a aHT market
     */
    constructor(aHT aHT_) public {
        aHT = aHT_;
    }

    /**
     * @notice msg.sender sends HT to repay an account's borrow in the aHT market
     * @dev The provided HT is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, aHT);
    }

    /**
     * @notice msg.sender sends HT to repay an account's borrow in a aHT market
     * @dev The provided HT is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param aHT_ The address of the aHT contract to repay in
     */
    function repayBehalfExplicit(address borrower, aHT aHT_) public payable {
        uint received = msg.value;
        uint borrows = aHT_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            aHT_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            aHT_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
