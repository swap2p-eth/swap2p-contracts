// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

/*╔════════════════════════════════════════════════════════════════════╗*\
║   Swap2p – non-custodial P2P swap of the native coin against fiat   ║
\*╚════════════════════════════════════════════════════════════════════╝*/

contract Swap2p {
    /*──────────────────────── CONSTANTS / TYPES ───────────────────────────*/

    uint32 public constant FEE_BPS      = 10;      // 0,10 %
    uint32 public constant AFF_SHARE_BP = 2000;    // 20 % от комиссии

    type FiatCode is uint24;                       // "USD" → 0x555344

    enum Side      { BUY, SELL }                   // намерение мейкера
    enum DealState { NONE, SELECTED, ACCEPTED, PAID, RELEASED, CANCELED }

    struct Offer {
        uint128 minAmt;
        uint128 maxAmt;
        uint96  reserveFiat;
        uint96  priceFiatPerToken;   // цена 1 e18 нативной монеты
        FiatCode fiat;
        uint32  ts;
        Side    side;
        bool    makerOnline;
    }

    struct Deal {
        uint128 amount;
        uint96  price;
        DealState state;
        Side    side;
        address maker;
        address taker;
        FiatCode fiat;
        uint40  tsSelect;
        uint40  tsLast;
    }

    struct MakerProfile {
        bool  online;
        uint8 startHourUTC;          // 0-23
        uint8 endHourUTC;            // 0-23
    }

    /*──────────────────────────── STORAGE ─────────────────────────────────*/

    address public immutable author;
    uint96  private  _dealSeq;

    // (maker ⇒ side ⇒ fiat) → Offer
    mapping(address => mapping(Side => mapping(FiatCode => Offer))) public offers;
    // id → Deal
    mapping(uint96  => Deal) public deals;

    // native кредиты, если push не прошёл
    mapping(address => uint128) public pending;

    // партнёрская программа (только для тейкеров)
    mapping(address => address) public affiliates;

    // профиль мейкера
    mapping(address => MakerProfile) public makerInfo;

    /*─── 1. Реестр активных оферов  ───────────────────────────────────────*/

    mapping(Side => mapping(FiatCode => address[]))                 private _offerKeys;
    mapping(address => mapping(Side => mapping(FiatCode => uint256))) private _offerPos; // +1

    /*─── 2. Реестр открытых сделок по адресу ──────────────────────────────*/

    mapping(address => uint96[])                  private _openDeals;
    mapping(address => mapping(uint96 => uint256)) private _openPos; // +1

    /*──────────────────────────── ERRORS ──────────────────────────────────*/

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

    /*──────────────────────────── EVENTS ──────────────────────────────────*/

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

    /*────────────────────────── CONSTRUCTOR ───────────────────────────────*/

    constructor() payable {
        author = msg.sender;
    }

    /*──────────────────── INTERNAL / MODIFIERS / HELPERS ──────────────────*/

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

    /*─── offer registry helpers ───────────────────────────────────────────*/

    function _addOfferKey(address maker, Side side, FiatCode fiat) private {
        if (_offerPos[maker][side][fiat] == 0) {
            _offerPos[maker][side][fiat] = _offerKeys[side][fiat].length + 1;
            _offerKeys[side][fiat].push(maker);
        }
    }
    function _removeOfferKey(address maker, Side side, FiatCode fiat) private {
        uint256 pos = _offerPos[maker][side][fiat];
        if (pos == 0) return;                   // уже нет
        uint256 idx = pos - 1;
        address[] storage arr = _offerKeys[side][fiat];
        uint256 last = arr.length - 1;
        if (idx != last) {
            address lastAddr = arr[last];
            arr[idx] = lastAddr;
            _offerPos[lastAddr][side][fiat] = pos;
        }
        arr.pop();
        delete _offerPos[maker][side][fiat];
    }

    /*─── open-deal registry helpers ───────────────────────────────────────*/

    function _addOpenDeal(address user, uint96 id) private {
        _openPos[user][id] = _openDeals[user].length + 1;
        _openDeals[user].push(id);
    }
    function _removeOpenDeal(address user, uint96 id) private {
        uint256 pos = _openPos[user][id];
        if (pos == 0) return;
        uint256 idx = pos - 1;
        uint96[] storage arr = _openDeals[user];
        uint256 last = arr.length - 1;
        if (idx != last) {
            uint96 lastId = arr[last];
            arr[idx] = lastId;
            _openPos[user][lastId] = pos;
        }
        arr.pop();
        delete _openPos[user][id];
    }
    function _closeDealForBoth(address maker, address taker, uint96 id) private {
        _removeOpenDeal(maker, id);
        _removeOpenDeal(taker, id);
    }

    /*─── payment helpers ──────────────────────────────────────────────────*/

    function _sendOrCredit(address to, uint128 amt) internal {
        if (amt == 0) return;
        (bool ok, ) = to.call{value: amt, gas: 25_000}("");
        if (ok) emit Payout(to, amt);
        else { pending[to] += amt; emit PendingCredit(to, amt); }
    }

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

    /*───────────────────── MAKER PROFILE  (не менялось) ───────────────────*/

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

    /*────────────────────── OFFER MANAGEMENT (add + key) ──────────────────*/

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
        // добавить в массив, если ранее не было
        _addOfferKey(msg.sender, side, fiat);

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
        _removeOfferKey(msg.sender, side, fiat);
        emit OfferDeleted(msg.sender, side, fiat);
    }

    /*──────────── SELECT (TAKER) – добавляем openDeals ────────────────────*/

    function taker_selectOffer(
        Side      side,
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

        _addOpenDeal(maker, id);
        _addOpenDeal(msg.sender, id);

        if (affiliates[msg.sender] == address(0) && partner != address(0)) {
            if (partner == msg.sender) revert SelfPartnerNotAllowed();
            affiliates[msg.sender] = partner;
            emit PartnerBound(msg.sender, partner);
        }

        emit DealSelected(id, side, maker, msg.sender, amount, paymentDetails);
    }

    /*─────────── CANCELLATIONS BEFORE ACCEPT  (close lists) ───────────────*/

    function taker_cancelSelect(uint96 id, string calldata reason)
    external onlyTaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        uint128 refund = d.side == Side.BUY ? d.amount * 2 : d.amount;
        _sendOrCredit(d.taker, refund);
        _closeDealForBoth(d.maker, d.taker, id);

        emit DealCanceled(id, reason);
    }

    function maker_cancelTaker(uint96 id, string calldata reason)
    external onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        uint128 refund = d.side == Side.BUY ? d.amount * 2 : d.amount;
        _sendOrCredit(d.taker, refund);
        _closeDealForBoth(d.maker, d.taker, id);

        emit DealCanceled(id, reason);
    }

    /*───────── ACCEPT, CHAT – без изменений в списках ─────────────────────*/

    function maker_acceptTaker(uint96 id, string calldata msgForTaker)
    external payable onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.SELECTED) revert WrongState();

        uint128 need = d.side == Side.BUY ? d.amount : d.amount * 2;
        if (msg.value != need) revert InsufficientDeposit();

        d.state  = DealState.ACCEPTED;
        d.tsLast = uint40(block.timestamp);
        emit DealAccepted(id, msgForTaker);
    }

    function maker_sendMessage(uint96 id, string calldata text)
    external onlyMaker(id)
    { DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text); }

    function taker_sendMessage(uint96 id, string calldata text)
    external onlyTaker(id)
    { DealState st = deals[id].state;
        if (st != DealState.ACCEPTED && st != DealState.PAID) revert WrongState();
        emit Chat(id, msg.sender, text); }

    /*────────  MAKER CANCEL AFTER ACCEPT  (close lists) ───────────────────*/

    function maker_cancelDeal(uint96 id, string calldata reason)
    external onlyMaker(id)
    {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        if (d.side == Side.BUY) {
            _sendOrCredit(d.taker, uint128(d.amount * 2));
            _sendOrCredit(d.maker, uint128(d.amount));
        } else {
            _sendOrCredit(d.taker, uint128(d.amount));
            _sendOrCredit(d.maker, uint128(d.amount * 2));
        }
        _closeDealForBoth(d.maker, d.taker, id);

        emit DealCanceled(id, reason);
    }

    /*──────────────  MARK FIAT PAID  (без изменений) ───────────────────────*/

    function markFiatPaid(uint96 id, string calldata msg_) external {
        Deal storage d = deals[id];
        if (d.state != DealState.ACCEPTED) revert WrongState();

        if ((d.side == Side.BUY  && msg.sender != d.maker) ||
            (d.side == Side.SELL && msg.sender != d.taker))
            revert NotFiatPayer();

        d.state  = DealState.PAID;
        d.tsLast = uint40(block.timestamp);
        emit DealPaid(id, msg_);
    }

    /*──────────────────── RELEASE  (close lists, payouts) ──────────────────*/

    function release(uint96 id) external {
        Deal storage d = deals[id];
        if (d.state != DealState.PAID) revert WrongState();

        if ((d.side == Side.BUY  && msg.sender != d.taker) ||
            (d.side == Side.SELL && msg.sender != d.maker))
            revert NotTaker();

        d.state  = DealState.RELEASED;
        d.tsLast = uint40(block.timestamp);

        address recipient = d.side == Side.BUY ? d.maker : d.taker;
        _payWithFee(d.taker, recipient, uint128(d.amount));

        _sendOrCredit(d.taker, uint128(d.amount));
        _sendOrCredit(d.maker, uint128(d.amount));

        _closeDealForBoth(d.maker, d.taker, id);

        emit DealReleased(id);
    }

    /*─────────────────────────── WITHDRAW ─────────────────────────────────*/

    function withdraw() external {
        uint128 amt = pending[msg.sender];
        if (amt == 0) revert WithdrawZero();
        pending[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert WithdrawFailed();
        emit Withdraw(msg.sender, amt);
    }

    /*─────────────────────────── READERS ───────────────────────────────────*/

    // 1) ордер-бук
    function getOfferCount(Side side, FiatCode fiat) external view returns (uint256) {
        return _offerKeys[side][fiat].length;
    }

    function getOfferKeys(
        Side side,
        FiatCode fiat,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory slice) {
        address[] storage arr = _offerKeys[side][fiat];
        uint256 len = arr.length;
        if (offset >= len) return new address[](0);

        uint256 end = offset + limit;
        if (end > len) end = len;

        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            slice[i - offset] = arr[i];
        }
    }


    // 2) мои открытые сделки
    function getOpenDealCount(address user) external view returns (uint256) {
        return _openDeals[user].length;
    }
    function getOpenDeals(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint96[] memory slice) {
        uint96[] storage arr = _openDeals[user];
        uint256 len = arr.length;
        if (offset >= len) return new uint96[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        slice = new uint96[](end - offset);
        for (uint256 i = offset; i < end; ++i) slice[i - offset] = arr[i];
    }

    // 3) пакетная доступность мейкеров
    function areMakersAvailable(address[] calldata makers)
    external
    view
    returns (bool[] memory avail)
    {
        uint256 len = makers.length;
        avail = new bool[](len);

        uint8 hour = uint8((block.timestamp / 1 hours) % 24);

        for (uint256 i; i < len; ++i) {
            MakerProfile storage p = makerInfo[makers[i]];
            if (!p.online) continue;

            bool ok;
            if (p.startHourUTC <= p.endHourUTC) {
                ok = (hour >= p.startHourUTC && hour <= p.endHourUTC);
            } else {
                ok = (hour >= p.startHourUTC || hour <= p.endHourUTC);
            }
            avail[i] = ok;
        }
    }

    /*────────────────────────── FALLBACKS ─────────────────────────────────*/

    receive() external payable {}
}
