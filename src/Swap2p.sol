// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/*╔════════════════════════════════════════════════════╗*\
║   Swap2p – non-custodial native-to-fiat P2P market  ║
\*╚════════════════════════════════════════════════════╝*/

contract Swap2p {
    /*────────────── CONSTANTS / TYPES ───────────────*/

    uint32 public constant FEE_BPS      = 10;      // 0,10 %
    uint32 public constant AFF_SHARE_BP = 2000;    // 20 % от комиссии

    type FiatCode is uint24;
    enum Side { BUY, SELL }
    enum DealState { NONE, SELECTED, ACCEPTED, PAID, RELEASED, CANCELED }

    struct Offer {
        uint128 minAmt;
        uint128 maxAmt;
        uint96  reserveFiat;
        uint96  priceFiatPerToken;
        FiatCode fiat;
        uint32  ts;
        Side    side;
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
        uint8 startHourUTC;
        uint8 endHourUTC;
    }

    /*────────────── STORAGE ─────────────────────────*/

    address public immutable author;
    uint96  private _dealSeq;

    mapping(address => mapping(Side => mapping(FiatCode => Offer))) public offers;
    mapping(uint96  => Deal) public deals;

    mapping(address => uint128) public pending;
    mapping(address => address) public affiliates;
    mapping(address => MakerProfile) public makerInfo;

    mapping(Side => mapping(FiatCode => address[])) private _offerKeys;
    mapping(address => mapping(Side => mapping(FiatCode => uint256))) private _offerPos; // +1

    mapping(address => uint96[])  private _openDeals;
    mapping(address => mapping(uint96 => uint256))   private _openPos; // +1

    /*────────────── ERRORS ──────────────────────────*/

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
    error Reentrancy();

    /*────────────── EVENTS (без изменений) ─────────*/

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

    /*────────────── CONSTRUCTOR ────────────────────*/
    constructor() payable { author = msg.sender; }

    /*────────────── MODIFIERS ──────────────────────*/
    modifier onlyMaker(uint96 id){ if(msg.sender!=deals[id].maker) revert NotMaker(); _;}
    modifier onlyTaker(uint96 id){ if(msg.sender!=deals[id].taker) revert NotTaker(); _;}

    /*────────────── OFFER-KEY HELPERS ──────────────*/
    function _addOfferKey(address m, Side s, FiatCode f) private {
        if (_offerPos[m][s][f]==0){
            _offerPos[m][s][f]=_offerKeys[s][f].length+1;
            _offerKeys[s][f].push(m);
        }
    }
    function _removeOfferKey(address m, Side s, FiatCode f) private {
        uint pos=_offerPos[m][s][f]; if(pos==0) return;
        address[] storage arr=_offerKeys[s][f];
        uint idx=pos-1; uint last=arr.length-1;
        if(idx!=last){ address lastA=arr[last]; arr[idx]=lastA; _offerPos[lastA][s][f]=pos;}
        arr.pop(); delete _offerPos[m][s][f];
    }

    /*────────────── OPEN-DEAL HELPERS ──────────────*/
    function _addOpen(address u,uint96 id) private { _openPos[u][id]=_openDeals[u].length+1; _openDeals[u].push(id); }
    function _removeOpen(address u,uint96 id) private {
        uint pos=_openPos[u][id]; if(pos==0)return;
        uint idx=pos-1; uint96[] storage arr=_openDeals[u];
        uint last=arr.length-1;
        if(idx!=last){ uint96 lastId=arr[last]; arr[idx]=lastId; _openPos[u][lastId]=pos;}
        arr.pop(); delete _openPos[u][id];
    }
    function _closeBoth(address m,address t,uint96 id) private { _removeOpen(m,id); _removeOpen(t,id); }

    /*────────────── PAYMENTS ───────────────────────*/
    function _sendOrCredit(address to,uint128 amt) internal{
        if(amt==0)return;
        (bool ok,)=to.call{value:amt,gas:50_000}("");
        if(ok) emit Payout(to,amt); else{ pending[to]+=amt; emit PendingCredit(to,amt);}
    }
    function _payWithFee(address taker,address to,uint128 amt) internal{
        uint128 fee=uint128((amt*FEE_BPS)/10_000);
        _sendOrCredit(to,amt-fee);
        address p=affiliates[taker];
        if(p!=address(0)){ uint128 share=uint128((fee*AFF_SHARE_BP)/10_000);
            _sendOrCredit(p,share); _sendOrCredit(author,fee-share);}
        else _sendOrCredit(author,fee);
    }

    /*────────────── MAKER PROFILE ─────────────────*/
    function setOnline(bool on) external{ makerInfo[msg.sender].online=on; emit MakerOnline(msg.sender,on);}
    function setWorkingHours(uint8 s,uint8 e) external{
        if(s>=24||e>=24) revert InvalidHour();
        makerInfo[msg.sender].startHourUTC=s; makerInfo[msg.sender].endHourUTC=e;
        emit WorkingHoursSet(msg.sender,s,e);
    }

    /*────────────── OFFER MANAGEMENT ──────────────*/
    function maker_makeOffer(
        Side s, FiatCode f, uint96 price, uint96 reserveFiat,
        uint128 minAmt,uint128 maxAmt,
        string calldata pay,string calldata comment
    ) external{
        _addOfferKey(msg.sender,s,f);
        offers[msg.sender][s][f]=Offer({
            minAmt:minAmt,maxAmt:maxAmt,reserveFiat:reserveFiat,
            priceFiatPerToken:price,fiat:f,ts:uint32(block.timestamp),side:s
        });
        emit OfferUpsert(msg.sender,s,f,offers[msg.sender][s][f],pay,comment);
    }

    /// «Мягкое» удаление: офер обнуляется, ключ выходит из массива только когда нет открытых сделок
    function maker_deleteOffer(Side s,FiatCode f) external{
        delete offers[msg.sender][s][f];
        if(_openDeals[msg.sender].length==0){ _removeOfferKey(msg.sender,s,f); }
        emit OfferDeleted(msg.sender,s,f);
    }

    /*────────────── SELECT (TAKER) ────────────────*/
    function taker_selectOffer(
        Side s,address maker,uint128 amount,FiatCode f,
        string calldata details,address partner
    ) external payable{
        Offer storage off=offers[maker][s][f];
        if(off.maxAmt==0) revert OfferNotFound();
        if(amount<off.minAmt||amount>off.maxAmt) revert AmountOutOfBounds();

        uint128 need=s==Side.BUY?amount*2:amount;
        if(msg.value!=need) revert InsufficientDeposit();

        uint96 id=++_dealSeq;
        deals[id]=Deal({
            amount:amount,price:off.priceFiatPerToken,state:DealState.SELECTED,
            side:s,maker:maker,taker:msg.sender,fiat:f,
            tsSelect:uint40(block.timestamp),tsLast:uint40(block.timestamp)
        });
        _addOpen(maker,id); _addOpen(msg.sender,id);

        if(affiliates[msg.sender]==address(0)&&partner!=address(0)){
            if(partner==msg.sender) revert SelfPartnerNotAllowed();
            affiliates[msg.sender]=partner; emit PartnerBound(msg.sender,partner);
        }
        emit DealSelected(id,s,maker,msg.sender,amount,details);
    }

    /*────────────── CANCELS до accept ─────────────*/
    function taker_cancelSelect(uint96 id,string calldata reason) external onlyTaker(id){
        Deal storage d=deals[id]; if(d.state!=DealState.SELECTED) revert WrongState();
        d.state=DealState.CANCELED; d.tsLast=uint40(block.timestamp);
        _sendOrCredit(d.taker,d.side==Side.BUY?uint128(d.amount*2):uint128(d.amount));
        _closeBoth(d.maker,d.taker,id); emit DealCanceled(id,reason);
    }
    function maker_cancelTaker(uint96 id,string calldata reason) external onlyMaker(id){
        Deal storage d=deals[id]; if(d.state!=DealState.SELECTED) revert WrongState();
        d.state=DealState.CANCELED; d.tsLast=uint40(block.timestamp);
        _sendOrCredit(d.taker,d.side==Side.BUY?uint128(d.amount*2):uint128(d.amount));
        _closeBoth(d.maker,d.taker,id); emit DealCanceled(id,reason);
    }

    /*────────────── ACCEPT / CHAT ────────────────*/
    function maker_acceptTaker(uint96 id,string calldata msg_) external payable onlyMaker(id){
        Deal storage d=deals[id]; if(d.state!=DealState.SELECTED) revert WrongState();
        uint128 need=d.side==Side.BUY?d.amount:d.amount*2;
        if(msg.value!=need) revert InsufficientDeposit();
        d.state=DealState.ACCEPTED; d.tsLast=uint40(block.timestamp);
        emit DealAccepted(id,msg_);
    }
    function maker_sendMessage(uint96 id,string calldata t) external onlyMaker(id){
        DealState st=deals[id].state; if(st!=DealState.ACCEPTED&&st!=DealState.PAID) revert WrongState();
        emit Chat(id,msg.sender,t);
    }
    function taker_sendMessage(uint96 id,string calldata t) external onlyTaker(id){
        DealState st=deals[id].state; if(st!=DealState.ACCEPTED&&st!=DealState.PAID) revert WrongState();
        emit Chat(id,msg.sender,t);
    }

    /*────────────── MAKER CANCEL после accept ────*/
    function maker_cancelDeal(uint96 id,string calldata reason) external onlyMaker(id){
        Deal storage d=deals[id]; if(d.state!=DealState.ACCEPTED) revert WrongState();
        d.state=DealState.CANCELED; d.tsLast=uint40(block.timestamp);
        if(d.side==Side.BUY){ _sendOrCredit(d.taker,uint128(d.amount*2)); _sendOrCredit(d.maker,uint128(d.amount)); }
        else{ _sendOrCredit(d.taker,uint128(d.amount)); _sendOrCredit(d.maker,uint128(d.amount*2)); }
        _closeBoth(d.maker,d.taker,id); emit DealCanceled(id,reason);
    }

    /*────────────── MARK PAID ─────────────────────*/
    function markFiatPaid(uint96 id,string calldata msg_) external{
        Deal storage d=deals[id]; if(d.state!=DealState.ACCEPTED) revert WrongState();
        if((d.side==Side.BUY&&msg.sender!=d.maker)||(d.side==Side.SELL&&msg.sender!=d.taker)) revert NotFiatPayer();
        d.state=DealState.PAID; d.tsLast=uint40(block.timestamp); emit DealPaid(id,msg_);
    }

    /*────────────── RELEASE ───────────────────────*/
    function release(uint96 id) external{
        Deal storage d=deals[id]; if(d.state!=DealState.PAID) revert WrongState();
        if((d.side==Side.BUY&&msg.sender!=d.taker)||(d.side==Side.SELL&&msg.sender!=d.maker)) revert NotTaker();

        d.state=DealState.RELEASED; d.tsLast=uint40(block.timestamp);
        _closeBoth(d.maker,d.taker,id);

        _payWithFee(d.taker,d.side==Side.BUY?d.maker:d.taker,uint128(d.amount));
        _sendOrCredit(d.taker,uint128(d.amount));
        _sendOrCredit(d.maker,uint128(d.amount));
        emit DealReleased(id);
    }

    /*────────────── WITHDRAW ──────────────────────*/
    uint private _entered;
    function withdraw() external{
        if(_entered==1) revert Reentrancy(); _entered=1;
        uint128 amt=pending[msg.sender]; if(amt==0){ _entered=0; revert WithdrawZero();}
        pending[msg.sender]=0;
        (bool ok,)=msg.sender.call{value:amt}("");
        _entered=0; if(!ok) revert WithdrawFailed();
        emit Withdraw(msg.sender,amt);
    }

    /*────────────── READERS (как было) ───────────*/
    function getOfferCount(Side s,FiatCode f) external view returns(uint){ return _offerKeys[s][f].length; }
    function getOfferKeys(Side s,FiatCode f,uint off,uint lim) external view returns(address[] memory out){
        address[] storage arr=_offerKeys[s][f]; uint len=arr.length;
        if(off>=len) return new address[](0); uint end=off+lim; if(end>len) end=len;
        out=new address[](end-off); for(uint i=off;i<end;++i) out[i-off]=arr[i];
    }
    function getOpenDealCount(address u) external view returns(uint){ return _openDeals[u].length; }
    function getOpenDeals(address u,uint off,uint lim) external view returns(uint96[] memory out){
        uint96[] storage arr=_openDeals[u]; uint len=arr.length;
        if(off>=len) return new uint96[](0); uint end=off+lim; if(end>len) end=len;
        out=new uint96[](end-off); for(uint i=off;i<end;++i) out[i-off]=arr[i];
    }
    function areMakersAvailable(address[] calldata m) external view returns(bool[] memory a){
        uint len=m.length; a=new bool[](len); uint8 h=uint8((block.timestamp/1 hours)%24);
        for(uint i;i<len;++i){ MakerProfile storage p=makerInfo[m[i]];
            if(!p.online) continue;
            a[i]=p.startHourUTC<=p.endHourUTC? (h>=p.startHourUTC&&h<=p.endHourUTC)
                : (h>=p.startHourUTC||h<=p.endHourUTC);}
    }

    /*────────────── FALLBACK ─────────────────────*/
    receive() external payable{}
}
