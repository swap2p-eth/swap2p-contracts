// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

/// @title Swap2p ― non-custodial P2P swapping of the native coin for fiat
/// @notice Dual-sided escrow: taker deposits 2×amount, maker deposits 1×amount
/// @dev Only the “BUY offer” flow is shown (maker buys crypto for fiat)

contract Swap2p {
    /* ─────────────────────────── CONSTANTS / TYPES ────────────────────────── */

    uint32 public constant FEE_BPS      = 10;      // 0.10 %
    uint32 public constant AFF_SHARE_BP = 2000;    // 20 % of the fee

    type FiatCode is uint24;                       // “USD” → 0x555344

    enum DealState {
        NONE,
        SELECTED,
        ACCEPTED,
        PAID,
        RELEASED,
        CANCELED
    }

    struct Offer {
        uint128 minAmt;
        uint128 maxAmt;
        uint96  reserveFiat;
        uint96  priceFiatPerToken;    // fiat per 1e18 native coin
        FiatCode fiat;
        uint32  ts;
        bool    makerOnline;          // snapshot at creation
    }

    struct Deal {
        uint128 amount;               // swap amount
        uint96  price;
        DealState state;
        address maker;
        address taker;
        FiatCode fiat;
        uint40  tsSelect;
        uint40  tsLast;
    }

    struct MakerProfile {
        bool  online;
        uint8 startHourUTC;           // inclusive, 0-23
        uint8 endHourUTC;             // inclusive, 0-23
    }

    /* ──────────────────────────── STORAGE ─────────────────────────────────── */

    address public immutable author;               // receives protocol fee
    uint96  private _dealSeq;                      // incremental id

    mapping(address => mapping(FiatCode => Offer)) public offers;     // maker → fiat → offer
    mapping(uint96  => Deal)                      public deals;       // id    → deal
    mapping(address => uint128)                  public pending;      // force-credited ETH

    mapping(address => address)                  public affiliates;   // taker → partner
    mapping(address => MakerProfile)             public makerInfo;

    /* ───────────────────────────── ERRORS ─────────────────────────────────── */

    error NotMaker();
    error NotTaker();
    error WrongState();
    error OfferNotFound();
    error AmountOutOfBounds();
    error NeedAmountAndCollateral();
    error AlreadyAccepted();
    error InvalidHour();
    error WithdrawZero();
    error WithdrawFailed();
    error SelfPartnerNotAllowed();

    /* ───────────────────────────── EVENTS ─────────────────────────────────── */

    event OfferUpsert(address indexed maker, FiatCode fiat, Offer offer, string payMethods, string comment);
    event OfferDeleted(address indexed maker, FiatCode fiat);

    event DealSelected(uint96 indexed id, address indexed maker, address indexed taker, uint128 amount, string paymentDetails);
    event DealCanceled(uint96 indexed id, string reason);
    event DealAccepted(uint96 indexed id, string makerMessage);
    event DealPaid(uint96 indexed id, string makerMessage);
    event DealReleased(uint96 indexed id);
    event Chat(uint96 indexed id, address indexed from, string text);

    event Payout(address indexed to, uint128 amount);
    event PendingCredit(address indexed to, uint128 amount);
    event Withdraw(address indexed to, uint128 amount);

    event PartnerBound(address indexed taker, address indexed partner);
    event MakerOnline(address indexed maker, bool online);
    event WorkingHoursSet(address indexed maker, uint8 startUTC, uint8 endUTC);

    /* ──────────────────────────── CONSTRUCTOR ─────────────────────────────── */

    constructor() payable {
        author = msg.sender;
    }

    /* ─────────────────────────── INTERNAL HELPERS ─────────────────────────── */

    modifier onlyMaker(uint96 id) {
        if (msg.sender != deals[id].maker) revert NotMaker();
        _;
    }
    modifier onlyTaker(uint96 id) {
        if (msg.sender != deals[id].taker) revert NotTaker();
        _;
    }

    function _nextId() private returns (uint96 id) {
        unchecked { id = ++_dealSeq; }
    }

    /// @dev Push ETH; credit on failure
    function _sendOrCredit(address to, uint128 amt) internal {
        if (amt == 0) return;
        (bool ok, ) = to.call{value: amt, gas: 25_000}("");
        if (ok) emit Payout(to, amt);
        else {
            pending[to] += amt;
            emit PendingCredit(to, amt);
        }
    }

    /// @dev Pay recipient, charge fee, split to partner if set
    function _payWithFee(address taker, address to, uint128 amt) internal {
        uint128 fee = uint128((amt * FEE_BPS) / 10_000);
        uint128 net = amt - fee;

        _sendOrCredit(to, net);

        address partner = affiliates[taker];
        if (partner != address(0)) {
            uint128 share = uint128((fee * AFF_SHARE_BP) / 10_000);
            _sendOrCredit(partner, share);
            _sendOrCredit(author, fee - share);
        } else {
            _sendOrCredit(author, fee);
        }
    }

    /* ───────────────────────── MAKER PROFILE API ──────────────────────────── */

    function setOnline(bool on) external {
        makerInfo[msg.sender].online = on;
        emit MakerOnline(msg.sender, on);
    }

    function setWorkingHours(uint8 startUTC, uint8 endUTC) external {
        if (startUTC >= 24 || endUTC >= 24) revert InvalidHour();
        makerInfo[msg.sender].startHourUTC = startUTC;
        makerInfo[msg.sender].endHourUTC   = endUTC;
        emit WorkingHoursSet(msg.sender, startUTC, endUTC);
    }

    /* ─────────────────────────── OFFER MANAGEMENT ─────────────────────────── */

    /// @notice Insert or update BUY offer; set amount == 0 to delete
    function maker_makeBuyOffer(
        FiatCode fiat,
        uint96   priceFiatPerToken,
        uint96   reserveFiat,
        uint128  minAmt,
        uint128  maxAmt,
        string calldata payMethods,
        string calldata comment
    ) external {
        offers[msg.sender][fiat] = Offer({
            minAmt:  minAmt,
            maxAmt:  maxAmt,
            reserveFiat: reserveFiat,
            priceFiatPerToken: priceFiatPerToken,
            fiat:    fiat,
            ts:      uint32(block.timestamp),
            makerOnline: makerInfo[msg.sender].online
        });
        emit OfferUpsert(msg.sender, fiat, offers[msg.sender][fiat], payMethods, comment);
    }

    function maker_deleteBuyOffer(FiatCode fiat) external {
        delete offers[msg.sender][fiat];
        emit OfferDeleted(msg.sender, fiat);
    }

    /* ───────────────────────────── SELECT (TAKER) ─────────────────────────── */

    /// @param partner  affiliate candidate; ignored if taker already bound
    function taker_selectBuyOffer(
        address  maker,
        uint128  dealAmount,
        FiatCode fiat,
        string calldata paymentDetails,
        address  partner
    ) external payable {
        Offer storage off = offers[maker][fiat];
        if (off.maxAmt == 0) revert OfferNotFound();
        if (dealAmount < off.minAmt || dealAmount > off.maxAmt) revert AmountOutOfBounds();
        if (msg.value != dealAmount * 2) revert NeedAmountAndCollateral();

        uint96 id = _nextId();
        deals[id] = Deal({
            amount: dealAmount,
            price:  off.priceFiatPerToken,
            state:  DealState.SELECTED,
            maker:  maker,
            taker:  msg.sender,
            fiat:   fiat,
            tsSelect: uint40(block.timestamp),
            tsLast:   uint40(block.timestamp)
        });

        if (affiliates[msg.sender] == address(0) && partner != msg.sender && partner != address(0)) {
            affiliates[msg.sender] = partner;
            emit PartnerBound(msg.sender, partner);
        } else if (partner == msg.sender) {
            revert SelfPartnerNotAllowed();
        }

        emit DealSelected(id, maker, msg.sender, dealAmount, paymentDetails);
    }

    /* ─────────────────────────── CANCELLATIONS ────────────────────────────── */

    function taker_cancelSelect(uint96 id, string calldata reason) external onlyTaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        _sendOrCredit(d.taker, uint128(d.amount * 2));
        emit DealCanceled(id, reason);
    }

    function maker_cancelTaker(uint96 id, string calldata reason) external onlyMaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        _sendOrCredit(d.taker, uint128(d.amount * 2));
        emit DealCanceled(id, reason);
    }

    /* ──────────────────────────── ACCEPT & FLOW ───────────────────────────── */

    function maker_acceptTaker(uint96 id, string calldata msgForTaker) external payable onlyMaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();
        if (msg.value != d.amount) revert NeedAmountAndCollateral(); // maker escrow = amount

        d.state  = DealState.ACCEPTED;
        d.tsLast = uint40(block.timestamp);

        emit DealAccepted(id, msgForTaker);
    }

    function maker_markPaid(uint96 id, string calldata msgForTaker) external onlyMaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        d.state  = DealState.PAID;
        d.tsLast = uint40(block.timestamp);

        emit DealPaid(id, msgForTaker);
    }

    function maker_cancelDeal(uint96 id, string calldata reason) external onlyMaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        _sendOrCredit(d.taker, uint128(d.amount * 2));
        _sendOrCredit(d.maker, uint128(d.amount));
        emit DealCanceled(id, reason);
    }

    function taker_release(uint96 id) external onlyTaker(id) {
        Deal storage d = deals[id];
        if (d.state != DealState.PAID) revert WrongState();

        d.state  = DealState.RELEASED;
        d.tsLast = uint40(block.timestamp);

        _payWithFee(d.taker, d.maker, uint128(d.amount)); // main payout with fee
        _sendOrCredit(d.taker, uint128(d.amount));        // taker collateral
        _sendOrCredit(d.maker, uint128(d.amount));        // maker collateral

        emit DealReleased(id);
    }

    /* ─────────────────────────────── CHAT ─────────────────────────────────── */

    function maker_sendMessage(uint96 id, string calldata text) external onlyMaker(id) {
        DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text);
    }

    function taker_sendMessage(uint96 id, string calldata text) external onlyTaker(id) {
        DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text);
    }

    /* ──────────────────────────── WITHDRAW ────────────────────────────────── */

    function withdraw() external {
        uint128 amt = pending[msg.sender];
        if (amt == 0) revert WithdrawZero();
        pending[msg.sender] = 0; // effects before interaction
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert WithdrawFailed();
        emit Withdraw(msg.sender, amt);
    }

    /* ────────────────────────── FALLBACKS ─────────────────────────────────── */

    receive() external payable {}
}
