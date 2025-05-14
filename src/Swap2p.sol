// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @dev Contract for non custodial P2P buy and sell native token for fiat currency
/// @dev Deals protected by dual-sided deposit escrow scheme (mutual escrow)
/// @dev So both sides interested to close the deal ASAP and return collaterals back
/// @dev Side BUY - buy crypto, SELL - Sell crypto (for fiat)
contract Swap2p {

    // TODO events for all state-changing functions

    // TODO custom errors

    address private immutable author;
    mapping (address => address) public partners; // TODO

    constructor() {
        author = msg.sender;
    }

    // TODO? go online / offline functions for MM
    // TODO? working hours for MM

    // BUY OFFER: Maker buys crypto for fiat, Taker sells crypto for fiat
    //////////////////////////////////////////////////////////////////////

    /// @dev Market maker makes buy crypto offer to market. Set amount to 0 to delete offer
    /// @notice Only one offer per side per fiat for market maker
    function maker_makeBuyOffer(
        string fiat, // 'USD', 'EUR' etc.
        uint price, // of 1e18 network token in fiat
        uint reserve, // in fiat
        uint minimumAmount, // of network token
        uint maximumAmount, // of network token
        string acceptedPaymentMethods, // comma-separated payment methods accepted by maker
        string comment // text comment related to the offer
    ) external {
        // TODO
    }

    /// @dev Taker selects Marketmaker's offer and creates a deal
    /// @dev amount in network token, fiat amount calculated under the hood
    /// @dev paymentDetails should contain
    /// @notice Taker should send amount*2 to contract (amount + 100% collateral)
    function taker_selectBuyOffer(address maker, uint dealAmount, string fiat, string paymentDetails)
    external payable {
        // TODO
    }

    /// @dev Taker can cancel offer selection while Maker did not accept this selection
    /// @dev Contract cancel the deal and refund amount and collateral to taker
    function taker_cancelSelect(address maker)
    external {
        // TODO
    }

    /// @dev Maker cancels taker's selection
    /// @dev Contract cancel the deal and refund amount and collateral to taker
    /// @dev optionalMessage can contains cancellation reason for taker
    function maker_cancelTaker(address taker, string optionalMessage)
    external {
        // TODO
    }

    /// @dev Maker accepts taker's selection
    /// @notice Maker should send amount of the deal as escrow collateral
    /// @dev optionalMessage can contains information related to the deal
    function maker_acceptTaker(address taker, string optionalMessage)
    external payable {
        // TODO
    }

    /// @dev After deal

    /// @dev Maker can cancel the deal while he did not transferred fiat money
    /// @dev for example when he have issues with bank transfer etc.
    /// @dev Contract cancel the deal and returns collateral to maker and collateral+deal amount to taker
    function maker_cancelDeal(address taker, string optionalMessage)
    external {
        // TODO
    }

    /// @dev Maker should make payment to Taker's fiat account and mark deal as paid
    function maker_markPaid(address taker, string optionalMessage)
    external {
        // TODO
    }

    /// @dev Taker should check fiat received then release (close) the deal
    /// @dev Contract deletes the deal, send deal amount to maker and returns both collaterals to sides
    function taker_release(address maker)
    external {
        // TODO
    }

    // SELL OFFER: Maker sells crypto for fiat, Taker buys crypto for fiat
    //////////////////////////////////////////////////////////////////////



}
