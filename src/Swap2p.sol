// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

contract Swap2p {
    /*──────────────────────────────────────────────────────*/
    /*  CONSTANTS & TYPES                                   */
    /*──────────────────────────────────────────────────────*/

    uint32 public constant FEE_BPS      = 10;     // 0.10 %
    uint32 public constant AFF_SHARE_BP = 2000;   // 20 %  (из комиссии)

    type FiatCode is uint24;                      // "USD" → 0x555344

    enum DealState { NONE, SELECTED, ACCEPTED, PAID, RELEASED, CANCELED }

    struct Offer {
        uint128 minAmt;
        uint128 maxAmt;
        uint96  reserveFiat;
        uint96  price;          // fiat per 1e18 native
        FiatCode fiat;
        uint32  ts;
        bool    online;         // maker status snapshot
    }

    struct Deal {
        uint128 amount;         // escrow сумма сделки
        uint96  price;
        DealState state;
        address maker;
        address taker;
        FiatCode fiat;
        uint40  tsSelect;
        uint40  tsLast;
    }

    struct MakerProfile {
        bool   online;          // 1 байт
        uint8  startHour;       // UTC 0-23
        uint8  endHour;         // UTC 0-23
    }

    /*──────────────────────────────────────────────────────*/
    /*  STORAGE                                             */
    /*──────────────────────────────────────────────────────*/

    address public immutable author;              // получает комиссию
    uint96  private  _dealSeq;                    // уникальные id

    mapping(address => mapping(FiatCode => Offer)) public offers;      // maker ⇒ fiat ⇒ offer
    mapping(uint96  => Deal)                      public deals;        // id    ⇒ deal
    mapping(address => uint128)                  public pendingWithdraw; // fallback-кредиты

    mapping(address => address)                  public affiliates;    // taker ⇒ партнёр
    mapping(address => MakerProfile)             public makerProfile;  // статус + часы

    /*──────────────────────────────────────────────────────*/
    /*  EVENTS                                              */
    /*──────────────────────────────────────────────────────*/

    event OfferUpsert(address indexed maker, FiatCode fiat, Offer offer, string payMethods, string comment);
    event OfferDeleted(address indexed maker, FiatCode fiat);
    event DealSelected(uint96 indexed id, address indexed maker, address indexed taker, uint128 amount, string paymentDetails);
    event DealCanceled(uint96 indexed id, string reason);
    event DealAccepted(uint96 indexed id, string msgFromMaker);
    event DealPaid(uint96 indexed id, string msgFromMaker);
    event DealReleased(uint96 indexed id);
    event Message(uint96 indexed id, address indexed from, string text);

    event Payout(address indexed to, uint128 amount);                 // off-chain учёт
    event PendingCredit(address indexed to, uint128 amount);          // когда push не прошёл
    event Withdraw(address indexed to, uint128 amount);
    event PartnerBound(address indexed taker, address indexed partner);

    event MakerOnline(address indexed maker, bool online);
    event WorkingHoursSet(address indexed maker, uint8 startHour, uint8 endHour);

    /*──────────────────────────────────────────────────────*/
    /*  CONSTRUCTOR                                         */
    /*──────────────────────────────────────────────────────*/

    constructor() payable {
        author = msg.sender;
    }

    /*──────────────────────────────────────────────────────*/
    /*  MODIFIERS & INTERNALS                               */
    /*──────────────────────────────────────────────────────*/

    modifier onlyMaker(uint96 id) { require(msg.sender == deals[id].maker, "Not maker"); _; }
    modifier onlyTaker(uint96 id) { require(msg.sender == deals[id].taker, "Not taker"); _; }

    function _nextId() private returns (uint96 id) { unchecked { id = ++_dealSeq; } }

    /// push ETH; если не удалось — кредитуем во внутренний счёт
    function _sendOrCredit(address to, uint128 amt) internal {
        if (amt == 0) return;
        (bool ok, ) = to.call{value: amt, gas: 25_000}("");
        if (ok) emit Payout(to, amt);
        else {
            pendingWithdraw[to] += amt;
            emit PendingCredit(to, amt);
        }
    }

    /// комиссия + партнёр
    function _payoutWithFee(address taker, address to, uint128 amt) internal {
        uint128 fee = uint128((amt * FEE_BPS) / 10_000);          // 0.1 %
        uint128 net = amt - fee;

        _sendOrCredit(to, net);                                   // основная выплата

        address partner = affiliates[taker];
        if (partner != address(0)) {
            uint128 part = uint128((fee * AFF_SHARE_BP) / 10_000);
            _sendOrCredit(partner, part);
            _sendOrCredit(author, fee - part);
        } else {
            _sendOrCredit(author, fee);
        }
    }

    /*──────────────────────────────────────────────────────*/
    /*  MAKER PROFILE                                       */
    /*──────────────────────────────────────────────────────*/

    function setOnline(bool on) external {
        makerProfile[msg.sender].online = on;
        emit MakerOnline(msg.sender, on);
    }

    function setWorkingHours(uint8 startHour, uint8 endHour) external {
        require(startHour < 24 && endHour < 24, "Hour 0-23");
        makerProfile[msg.sender].startHour = startHour;
        makerProfile[msg.sender].endHour   = endHour;
        emit WorkingHoursSet(msg.sender, startHour, endHour);
    }

    /*──────────────────────────────────────────────────────*/
    /*  OFFERS (BUY)                                        */
    /*──────────────────────────────────────────────────────*/

    function maker_makeBuyOffer(
        FiatCode fiat,
        uint96   price,               // fiat per 1e18 native
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
            price:   price,
            fiat:    fiat,
            ts:      uint32(block.timestamp),
            online:  makerProfile[msg.sender].online
        });
        emit OfferUpsert(msg.sender, fiat, offers[msg.sender][fiat], payMethods, comment);
    }

    function maker_deleteBuyOffer(FiatCode fiat) external {
        delete offers[msg.sender][fiat];
        emit OfferDeleted(msg.sender, fiat);
    }

    /*──────────────────────────────────────────────────────*/
    /*  SELECT  (тейкер)                                    */
    /*──────────────────────────────────────────────────────*/

    function taker_selectBuyOffer(
        address  maker,
        uint128  dealAmount,          // native, 1e18
        FiatCode fiat,
        string calldata paymentDetails,
        address  partner              // аффилиат-кандидат
    ) external payable {
        Offer storage off = offers[maker][fiat];
        require(off.maxAmt != 0,                  "No offer");
        require(dealAmount >= off.minAmt && dealAmount <= off.maxAmt, "Out of bounds");
        require(msg.value == dealAmount * 2,      "Need amount+collateral");

        uint96 id = _nextId();
        deals[id] = Deal({
            amount: dealAmount,
            price:  off.price,
            state:  DealState.SELECTED,
            maker:  maker,
            taker:  msg.sender,
            fiat:   fiat,
            tsSelect: uint40(block.timestamp),
            tsLast:   uint40(block.timestamp)
        });

        // записываем партнёра, если ещё не был
        if (affiliates[msg.sender] == address(0) && partner != msg.sender && partner != address(0)) {
            affiliates[msg.sender] = partner;
            emit PartnerBound(msg.sender, partner);
        }

        emit DealSelected(id, maker, msg.sender, dealAmount, paymentDetails);
    }

    /*──────────────────────────────────────────────────────*/
    /*  CANCEL  (тейкер до акцепта)                         */
    /*──────────────────────────────────────────────────────*/

    function taker_cancelSelect(uint96 id, string calldata reason) external onlyTaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.SELECTED, "Not selectable");

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        _sendOrCredit(d.taker, uint128(d.amount * 2));           // вернуть и сумму, и залог

        emit DealCanceled(id, reason);
    }

    /*──────────────────────────────────────────────────────*/
    /*  CANCEL  (maker до акцепта)                          */
    /*──────────────────────────────────────────────────────*/

    function maker_cancelTaker(uint96 id, string calldata reason) external onlyMaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.SELECTED, "Already accepted");

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        _sendOrCredit(d.taker, uint128(d.amount * 2));

        emit DealCanceled(id, reason);
    }

    /*──────────────────────────────────────────────────────*/
    /*  ACCEPT  (maker)                                     */
    /*──────────────────────────────────────────────────────*/

    function maker_acceptTaker(uint96 id, string calldata msgForTaker) external payable onlyMaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.SELECTED, "Wrong state");
        require(msg.value == d.amount,         "Need collateral");

        d.state  = DealState.ACCEPTED;
        d.tsLast = uint40(block.timestamp);

        emit DealAccepted(id, msgForTaker);
    }

    /*──────────────────────────────────────────────────────*/
    /*  CHAT                                                */
    /*──────────────────────────────────────────────────────*/

    function maker_sendMessage(uint96 id, string calldata text) external onlyMaker(id) {
        require(deals[id].state == DealState.ACCEPTED || deals[id].state == DealState.PAID, "Chat closed");
        emit Message(id, msg.sender, text);
    }

    function taker_sendMessage(uint96 id, string calldata text) external onlyTaker(id) {
        require(deals[id].state == DealState.ACCEPTED || deals[id].state == DealState.PAID, "Chat closed");
        emit Message(id, msg.sender, text);
    }

    /*──────────────────────────────────────────────────────*/
    /*  MAKER: cancel после accept (не перевёл деньги)      */
    /*──────────────────────────────────────────────────────*/

    function maker_cancelDeal(uint96 id, string calldata reason) external onlyMaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.ACCEPTED, "Not accepted");

        d.state  = DealState.CANCELED;
        d.tsLast = uint40(block.timestamp);

        // вернуть: тейкеру (amount+collateral), мейкеру collateral
        _sendOrCredit(d.taker, uint128(d.amount * 2));
        _sendOrCredit(d.maker, uint128(d.amount));

        emit DealCanceled(id, reason);
    }

    /*──────────────────────────────────────────────────────*/
    /*  MAKER → mark paid (fiat отправлен)                  */
    /*──────────────────────────────────────────────────────*/

    function maker_markPaid(uint96 id, string calldata msgForTaker) external onlyMaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.ACCEPTED, "Wrong state");

        d.state  = DealState.PAID;
        d.tsLast = uint40(block.timestamp);

        emit DealPaid(id, msgForTaker);
    }

    /*──────────────────────────────────────────────────────*/
    /*  TAKER → release (успех сделки)                      */
    /*──────────────────────────────────────────────────────*/

    function taker_release(uint96 id) external onlyTaker(id) {
        Deal storage d = deals[id];
        require(d.state == DealState.PAID, "Not paid");
        d.state  = DealState.RELEASED;
        d.tsLast = uint40(block.timestamp);

        // 1) выплата мейкеру (с комиссией)
        _payoutWithFee(d.taker, d.maker, uint128(d.amount));

        // 2) возврат залогов
        _sendOrCredit(d.taker, uint128(d.amount));  // collateral тейкера
        _sendOrCredit(d.maker, uint128(d.amount));  // collateral мейкера

        emit DealReleased(id);
    }

    /*──────────────────────────────────────────────────────*/
    /*  WITHDRAW (забрать кредиты)                          */
    /*──────────────────────────────────────────────────────*/

    function withdraw() external {
        uint128 amt = pendingWithdraw[msg.sender];
        require(amt != 0, "Zero");
        pendingWithdraw[msg.sender] = 0;         // effects-before-interactions
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "Withdraw failed");
        emit Withdraw(msg.sender, amt);
    }

    /*──────────────────────────────────────────────────────*/
    /*  FALLBACK                                            */
    /*──────────────────────────────────────────────────────*/

    receive() external payable {}    // контракт может принимать ETH напрямую
}
