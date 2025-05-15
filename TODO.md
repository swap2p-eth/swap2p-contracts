# TODO
- Выплаты автору: address private immutable author;
  constructor() {
      author = msg.sender;
  }
- Affiliate partners: mapping (address => address) public takerPartners; // when set, send 20% of fees to partner
- immutable fee = 0.1% (from deal amount) 
- on release only (not cancel)  send fees to author and affiliate (if set)
- profile
- go online / offline functions for maker
- working hours for maker (UTC)
- events for all state-changing functions
