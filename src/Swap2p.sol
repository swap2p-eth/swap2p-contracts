// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

/*╔════════════════════════════════════════════════════════════════════╗*\
║   Swap2p ‒ non-custodial P2P swap of the native coin against fiat   ║
║   Dual-side escrow + partner fee split. Supports BUY *and* SELL.    ║
\*╚════════════════════════════════════════════════════════════════════╝*/

contract Swap2p {
    /*────────────────────────── CONSTANTS / TYPES ──────────────────────────*/

    uint32 public constant FEE_BPS      = 10;      // 0.10 %
    uint32 public constant AFF_SHARE_BP = 2000;    // 20 % of the fee

    type FiatCode is uint24;                       // "USD" → 0x555344

    enum Side      { BUY, SELL }                  // maker’s intent
    enum DealState { NONE, SELECTED, ACCEPTED, PAID, RELEASED, CANCELED }

    struct Offer {
        uint128 minAmt;
        uint128 maxAmt;
        uint96  reserveFiat;
        uint96  priceFiatPerToken;    // fiat per 1 e18 native coin
        FiatCode fiat;
        uint32  ts;
        Side    side;                 // 1 byte
        bool    makerOnline;          // 1 byte
    }

    struct Deal {
        uint128 amount;
        uint96  price;
        DealState state;              // 1 byte
        Side    side;                 // 1 byte
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

    /*──────────────────────────── STORAGE ──────────────────────────────────*/

    address public immutable author;               // receives protocol fee
    uint96  private  _dealSeq;                     // incremental id

    // maker ⇒ side ⇒ fiat ⇒ offer
    mapping(address => mapping(Side => mapping(FiatCode => Offer))) public offers;
    // id ⇒ deal
    mapping(uint96 => Deal) public deals;

    // force-credited ETH when push transfer failed
    mapping(address => uint128) public pending;

    // taker ⇒ partner
    mapping(address => address) public affiliates;
    // maker profile (online + working hours)
    mapping(address => MakerProfile) public makerInfo;

    /*──────────────────────────── ERRORS ───────────────────────────────────*/

    error NotMaker();
    error NotTaker();
    error WrongState();
    error OfferNotFound();
    error AmountOutOfBounds();
    error InsufficientDeposit();
    error InvalidHour();
    error WithdrawZero();
    error WithdrawFailed();
    error SelfPartnerNotAllowed();
    error NotFiatPayer();

    /*──────────────────────────── EVENTS ───────────────────────────────────*/

    event OfferUpsert(address indexed maker, Side side, FiatCode fiat, Offer offer,
        string payMethods, string comment);
    event OfferDeleted(address indexed maker, Side side, FiatCode fiat);

    event DealSelected(uint96 indexed id, Side side, address indexed maker,
        address indexed taker, uint128 amount, string paymentDetails);
    event DealCanceled(uint96 indexed id, string reason);
    event DealAccepted(uint96 indexed id, string makerMessage);
    event DealPaid(uint96 indexed id, string message);
    event DealReleased(uint96 indexed id);
    event Chat(uint96 indexed id, address indexed from, string text);

    event Payout(address indexed to, uint128 amount);
    event PendingCredit(address indexed to, uint128 amount);
    event Withdraw(address indexed to, uint128 amount);

    event PartnerBound(address indexed taker, address indexed partner);
    event MakerOnline(address indexed maker, bool online);
    event WorkingHoursSet(address indexed maker, uint8 startUTC, uint8 endUTC);

    /*────────────────────────── CONSTRUCTOR ────────────────────────────────*/

    constructor() payable {
        author = msg.sender;
    }

    /*────────────────────────── INTERNAL HELPERS ───────────────────────────*/

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

    /// push ETH; on failure credit to internal balance
    function _sendOrCredit(address to, uint128 amt) internal {
        if (amt == 0) return;
        (bool ok, ) = to.call{value: amt, gas: 25_000}("");
        if (ok) emit Payout(to, amt);
        else {
            pending[to] += amt;
            emit PendingCredit(to, amt);
        }
    }

    /// payout with protocol fee and optional partner split
    function _payWithFee(address taker, address recipient, uint128 amt) internal {
        uint128 fee = uint128((amt * FEE_BPS) / 10_000);
        uint128 net = amt - fee;

        _sendOrCredit(recipient, net);

        address partner = affiliates[taker];
        if (partner != address(0)) {
            uint128 share = uint128((fee * AFF_SHARE_BP) / 10_000);
            _sendOrCredit(partner, share);
            _sendOrCredit(author, fee - share);
        } else {
            _sendOrCredit(author, fee);
        }
    }

    /*────────────────────────── MAKER PROFILE ──────────────────────────────*/

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

    /*──────────────────────── OFFER MANAGEMENT ─────────────────────────────*/

    /// @notice Insert / update offer. Set minAmt == 0 to delete.
    function maker_makeOffer(
        Side      side,
        FiatCode  fiat,
        uint96    priceFiatPerToken,
        uint96    reserveFiat,
        uint128   minAmt,
        uint128   maxAmt,
        string calldata payMethods,
        string calldata comment
    ) external {
        offers[msg.sender][side][fiat] = Offer({
            minAmt:  minAmt,
            maxAmt:  maxAmt,
            reserveFiat: reserveFiat,
            priceFiatPerToken: priceFiatPerToken,
            fiat:    fiat,
            ts:      uint32(block.timestamp),
            side:    side,
            makerOnline: makerInfo[msg.sender].online
        });

        emit OfferUpsert(msg.sender, side, fiat,
            offers[msg.sender][side][fiat], payMethods, comment);
    }

    function maker_deleteOffer(Side side, FiatCode fiat) external {
        delete offers[msg.sender][side][fiat];
        emit OfferDeleted(msg.sender, side, fiat);
    }

    /*─────────────────────────── SELECT (TAKER) ────────────────────────────*/

    /// @param partner  affiliate candidate; ignored if taker already has one
    function taker_selectOffer(
        Side      side,          // side of the maker’s offer
        address   maker,
        uint128   amount,
        FiatCode  fiat,
        string calldata paymentDetails,
        address   partner
    ) external payable {
        Offer storage off = offers[maker][side][fiat];
        if (off.maxAmt == 0) revert OfferNotFound();
        if (amount < off.minAmt || amount > off.maxAmt) revert AmountOutOfBounds();

        uint128 takerDeposit = side == Side.BUY ? amount * 2 : amount;
        if (msg.value != takerDeposit) revert InsufficientDeposit();

        uint96 id = _nextId();
        deals[id] = Deal({
            amount: amount,
            price:  off.priceFiatPerToken,
            state:  DealState.SELECTED,
            side:   side,
            maker:  maker,
            taker:  msg.sender,
            fiat:   fiat,
            tsSelect: uint40(block.timestamp),
            tsLast:   uint40(block.timestamp)
        });

        if (affiliates[msg.sender] == address(0) && partner != address(0)) {
            if (partner == msg.sender) revert SelfPartnerNotAllowed();
            affiliates[msg.sender] = partner;
            emit PartnerBound(msg.sender, partner);
        }

        emit DealSelected(id, side, maker, msg.sender, amount, paymentDetails);
    }

    /*──────────────────────── CANCELLATIONS BEFORE ACCEPT ───────────────────*/

    function taker_cancelSelect(uint96 id, string calldata reason)
    external
    onlyTaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        uint128 refund = d.side == Side.BUY ? d.amount * 2 : d.amount;
        _sendOrCredit(d.taker, refund);

        emit DealCanceled(id, reason);
    }

    function maker_cancelTaker(uint96 id, string calldata reason)
    external
    onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        uint128 refund = d.side == Side.BUY ? d.amount * 2 : d.amount;
        _sendOrCredit(d.taker, refund);

        emit DealCanceled(id, reason);
    }

    /*──────────────────────── ACCEPT (MAKER) ────────────────────────────────*/

    function maker_acceptTaker(uint96 id, string calldata msgForTaker)
    external
    payable
    onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        uint128 requiredDeposit = d.side == Side.BUY ? d.amount : d.amount * 2;
        if (msg.value != requiredDeposit) revert InsufficientDeposit();

        d.state  = DealState.ACCEPTED;
        d.tsLast = uint40(block.timestamp);

        emit DealAccepted(id, msgForTaker);
    }

    /*────────────────────────── CHAT (after accept) ─────────────────────────*/

    function maker_sendMessage(uint96 id, string calldata text)
    external
    onlyMaker(id)
    {
        DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text);
    }

    function taker_sendMessage(uint96 id, string calldata text)
    external
    onlyTaker(id)
    {
        DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text);
    }

    /*───────────────────── MAKER CANCEL AFTER ACCEPT ────────────────────────*/

    function maker_cancelDeal(uint96 id, string calldata reason)
    external
    onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        if (d.side == Side.BUY) {
            // refund taker 2×, maker 1×
            _sendOrCredit(d.taker, uint128(d.amount * 2));
            _sendOrCredit(d.maker, uint128(d.amount));
        } else {
            // SELL: refund taker 1×, maker 2×
            _sendOrCredit(d.taker, uint128(d.amount));
            _sendOrCredit(d.maker, uint128(d.amount * 2));
        }

        emit DealCanceled(id, reason);
    }

    /*──────────────────────────  MARK FIAT PAID  ────────────────────────────*/

    function markFiatPaid(uint96 id, string calldata message) external {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        // fiat payer: BUY -> maker,  SELL -> taker
        if (
            (d.side == Side.BUY  && msg.sender != d.maker) ||
            (d.side == Side.SELL && msg.sender != d.taker)
        ) revert NotFiatPayer();

        d.state  = DealState.PAID;
        d.tsLast = uint40(block.timestamp);

        emit DealPaid(id, message);
    }

    /*────────────────────────────  RELEASE  ─────────────────────────────────*/

    function release(uint96 id) external {
        Deal storage d = deals[id];
        if (d.state != DealState.PAID) revert WrongState();

        // fiat receiver: BUY -> taker, SELL -> maker
        if (
            (d.side == Side.BUY  && msg.sender != d.taker) ||
            (d.side == Side.SELL && msg.sender != d.maker)
        ) revert NotTaker(); // reuse as generic "not allowed"

        d.state  = DealState.RELEASED;
        d.tsLast = uint40(block.timestamp);

        // 1) main payout (swap amount)
        address recipient = d.side == Side.BUY ? d.maker : d.taker;
        _payWithFee(d.taker, recipient, uint128(d.amount));

        // 2) return collaterals
        if (d.side == Side.BUY) {
            _sendOrCredit(d.taker, uint128(d.amount));        // taker collateral
            _sendOrCredit(d.maker, uint128(d.amount));        // maker collateral
        } else {
            _sendOrCredit(d.taker, uint128(d.amount));        // taker collateral
            _sendOrCredit(d.maker, uint128(d.amount));        // maker collateral
        }

        emit DealReleased(id);
    }

    /*────────────────────────────  WITHDRAW  ────────────────────────────────*/

    function withdraw() external {
        uint128 amt = pending[msg.sender];
        if (amt == 0) revert WithdrawZero();
        pending[msg.sender] = 0;           // effects before interaction
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert WithdrawFailed();
        emit Withdraw(msg.sender, amt);
    }

    /*──────────────────────────── FALLBACKS ────────────────────────────────*/

    receive() external payable {}
}
