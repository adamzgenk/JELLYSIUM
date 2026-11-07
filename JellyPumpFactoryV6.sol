// SPDX-License-Identifier: MIT
// Jelly Pump v5 — Elysium Testnet ONLY, NOT AUDITED, DO NOT USE ON MAINNET.
// Built from v4 (same bonding curve, same 2% total fee) plus the approved
// v5 spec: limit orders, anti-snipe, holder rewards, buyback-and-burn,
// graduation as a milestone (not a trading halt).
//
// Honest design notes (read before using):
//  - Holder rewards need per-holder checkpoints, but a plain ERC20 does
//    not tell the factory about transfers. JellyTokenV6 therefore calls
//    factory.syncHolder(from, to) BEFORE balances change in _update, so
//    checkpoints use pre-transfer balances (a buyer never earns on the
//    trade that just happened; a seller keeps earnings up to the sale).
//    The factory only accepts syncHolder from its own registered tokens.
//  - Buyback on a pure bonding curve has no external market to buy from.
//    buybackAndBurn is therefore a SELF-BUY: treasury HYPE funds an
//    internal buy (sold rises, so the curve price rises), the bought
//    tokens are burned to the dead address, and hypeRaised is NOT
//    increased — graduation stays external-HYPE-based. The fee on the
//    self-buy is charged normally (recipients get paid, holder index
//    grows). This is stated here so nobody mistakes it for a DEX buy.
//  - Limit orders are on-chain escrow, whole-fill only. Buy escrow must
//    cover maxPrice * amount * 1.02, so an executable order can always
//    be filled; the excess is refunded. Tokens in limit-sell escrow do
//    NOT accrue holder rewards while escrowed (their balanceOf dropped
//    at placement); they resume accruing if cancelled.
//  - Graduation (100 HYPE) sets the flag and emits Graduated but does
//    NOT halt trading, unlike v4. Migration still needs a verified DEX
//    router (none exists on Elysium yet) and stays router-gated.
//  - Treasury is internal per-token accrual for buyback. There is NO
//    treasury payout address in v5 (v4's third constructor arg is gone).
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFactoryV6 {
    function syncHolder(address from, address to) external;
}

contract JellyTokenV6 is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {}
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    // Checkpoint holder rewards BEFORE balances change, so checkpoints
    // always use pre-transfer balances. Fail-closed: if syncHolder
    // reverts, the transfer reverts (accounting is never silently wrong).
    function _update(address from, address to, uint256 value) internal override {
        address f = owner();
        if (f != address(0)) {
            IFactoryV6(f).syncHolder(from, to);
        }
        super._update(from, to, value);
    }
}

contract JellyPumpFactoryV6 is Ownable {
    struct TokenInfo {
        address token;
        address creator;
        uint256 sold;
        uint256 hypeRaised;
        bool graduated;
        bool migrated;
        uint256 creationTime; // appended last: tokens(i) word layout for the first 6 fields is unchanged from v4
    }

    struct Order {
        address token;
        address owner;
        bool isBuy;
        uint256 amount;
        uint256 price; // buy: max average price (wei/token); sell: min average price
        uint256 escrow; // buy: escrowed HYPE (wei); sell: 0 (tokens escrowed instead)
        uint256 tokenEscrow; // sell: escrowed tokens; buy: 0
        bool active;
    }

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant BASE_PRICE = 1e12;
    uint256 public constant SLOPE = 1250;
    uint256 public constant GRADUATION_HYPE = 100 ether;
    uint256 public constant FEE_BPS = 200; // 2% total trade fee
    // Shares of the fee (must sum to 100):
    uint256 public constant CREATOR_SHARE = 30;
    uint256 public constant HOLDER_SHARE = 15;
    uint256 public constant ECOSYSTEM_SHARE = 5;
    uint256 public constant REFERRAL_SHARE = 15;
    uint256 public constant TREASURY_SHARE = 15;
    uint256 public constant PLATFORM_SHARE = 20;
    uint256 public constant MAX_INITIAL_BUY = 50_000_000 ether; // 5% of supply
    uint256 public constant ONE = 1 ether;
    uint256 public constant PRECISION = 1e18; // reward-per-token scaling
    uint256 public constant ANTI_SNIPE_WINDOW = 60; // seconds after creation
    uint256 public constant ANTI_SNIPE_CAP = 10_000_000 ether; // 1% of supply
    uint256 public constant MIN_BUY_ORDER_HYPE = 0.001 ether;
    uint256 public constant MIN_SELL_ORDER_TOKENS = 1000 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public feeTo; // platform
    address public ecosystemFund;
    address public dexRouter;
    TokenInfo[] public tokens;
    mapping(address => uint256) public tokenIndex;
    mapping(address => address) public referrerOf; // trader => referrer, set once
    mapping(address => mapping(address => uint256)) public boughtInWindowOf; // token => buyer => amount in window
    mapping(address => uint256) public rewardPerTokenStored; // token => index (PRECISION-scaled)
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewardsOwed;
    mapping(address => uint256) public treasuryAccrued; // token => HYPE held for buyback
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public orderIdsByToken;
    uint256 public nextOrderId;

    event TokenCreated(address indexed token, address indexed creator, string name, string symbol);
    event Bought(address indexed token, address indexed buyer, uint256 hypeIn, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, uint256 tokensIn, uint256 hypeOut);
    event Graduated(address indexed token, uint256 hypeRaised);
    event RouterSet(address indexed router);
    event Migrated(address indexed token, uint256 tokensLocked, uint256 hypeLocked);
    event ReferrerSet(address indexed trader, address indexed referrer);
    event LimitOrderPlaced(uint256 indexed orderId, address indexed token, address indexed owner, bool isBuy, uint256 amount, uint256 price);
    event LimitOrderExecuted(uint256 indexed orderId, address indexed token, address indexed owner, bool isBuy, uint256 amount);
    event LimitOrderCancelled(uint256 indexed orderId, address indexed token, address indexed owner);
    event HolderRewardClaimed(address indexed token, address indexed holder, uint256 amount);
    event BuybackBurned(address indexed token, uint256 tokensBurned, uint256 hypeSpent, uint256 feePaid);

    constructor(address feeTo_, address ecosystemFund_) Ownable(msg.sender) {
        feeTo = feeTo_;
        ecosystemFund = ecosystemFund_;
    }

    function setDexRouter(address router_) external onlyOwner {
        dexRouter = router_;
        emit RouterSet(router_);
    }

    function setReferrer(address referrer_) external {
        require(referrer_ != address(0), "zero referrer");
        require(referrer_ != msg.sender, "self referral");
        require(referrerOf[msg.sender] == address(0), "referrer already set");
        referrerOf[msg.sender] = referrer_;
        emit ReferrerSet(msg.sender, referrer_);
    }

    function _create(string calldata name_, string calldata symbol_) internal returns (address) {
        JellyTokenV6 token = new JellyTokenV6(name_, symbol_);
        // Register BEFORE minting: the mint triggers the token's _update
        // hook, which calls syncHolder, which requires a registered token.
        tokens.push(TokenInfo({token: address(token), creator: msg.sender, sold: 0, hypeRaised: 0, graduated: false, migrated: false, creationTime: block.timestamp}));
        tokenIndex[address(token)] = tokens.length;
        token.mint(address(this), SUPPLY);
        emit TokenCreated(address(token), msg.sender, name_, symbol_);
        return address(token);
    }

    function createToken(string calldata name_, string calldata symbol_) external returns (address) {
        return _create(name_, symbol_);
    }

    function createTokenWithInitialBuy(string calldata name_, string calldata symbol_, uint256 amount) external payable returns (address) {
        require(amount > 0 && amount <= MAX_INITIAL_BUY, "initial buy out of range");
        address tokenAddr = _create(name_, symbol_);
        // Buy at launch price (sold == 0) in the deploy transaction.
        // Exempt from the anti-snipe cap by construction: this path never
        // touches boughtInWindowOf (the cap is for later market buys).
        uint256 cost = buyCost(tokenAddr, amount);
        uint256 fee = (cost * FEE_BPS) / 10000;
        uint256 total = cost + fee;
        require(msg.value >= total, "not enough hype");
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        t.sold += amount;
        t.hypeRaised += cost;
        _payFee(tokenAddr, msg.sender, fee);
        require(IERC20(tokenAddr).transfer(msg.sender, amount), "transfer failed");
        if (msg.value > total) payable(msg.sender).transfer(msg.value - total);
        emit Bought(tokenAddr, msg.sender, total, amount);
        return tokenAddr;
    }

    function price(address tokenAddr) public view returns (uint256) {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        return BASE_PRICE + (SLOPE * t.sold) / ONE;
    }

    // Exact integrated cost, in wei, with full 18-decimal scaling
    // (same formula as v4.1 — not re-derived).
    function buyCost(address tokenAddr, uint256 amount) public view returns (uint256) {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        uint256 basePart = (BASE_PRICE * amount) / ONE;
        uint256 curvePart = (SLOPE * ((t.sold * amount) + (amount * amount) / 2)) / (ONE * ONE);
        return basePart + curvePart;
    }

    function sellRevenue(address tokenAddr, uint256 amount) public view returns (uint256) {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        require(amount <= t.sold, "sell more than sold");
        uint256 basePart = (BASE_PRICE * amount) / ONE;
        uint256 curvePart = (SLOPE * ((t.sold * amount) - (amount * amount) / 2)) / (ONE * ONE);
        return basePart + curvePart;
    }

    function _payFee(address tokenAddr, address trader, uint256 fee) internal {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        uint256 creatorFee = (fee * CREATOR_SHARE) / 100;
        uint256 holderFee = (fee * HOLDER_SHARE) / 100;
        uint256 ecosystemFee = (fee * ECOSYSTEM_SHARE) / 100;
        uint256 referralFee = (fee * REFERRAL_SHARE) / 100;
        uint256 treasuryFee = (fee * TREASURY_SHARE) / 100;
        uint256 platformFee = fee - creatorFee - holderFee - ecosystemFee - referralFee - treasuryFee;
        address ref = referrerOf[trader];
        if (creatorFee > 0) payable(t.creator).transfer(creatorFee);
        if (ecosystemFee > 0) payable(ecosystemFund).transfer(ecosystemFee);
        if (ref != address(0)) {
            if (referralFee > 0) payable(ref).transfer(referralFee);
        } else {
            platformFee += referralFee;
        }
        if (platformFee > 0) payable(feeTo).transfer(platformFee);
        if (holderFee > 0) {
            if (t.sold > 0) {
                rewardPerTokenStored[tokenAddr] += (holderFee * PRECISION) / t.sold;
            } else {
                // No holders exist (everything sold back): route the
                // holder slice to buyback fuel instead of dividing by 0.
                treasuryAccrued[tokenAddr] += holderFee;
            }
        }
        if (treasuryFee > 0) treasuryAccrued[tokenAddr] += treasuryFee;
    }

    function _updateReward(address tokenAddr, address user) internal {
        uint256 index = rewardPerTokenStored[tokenAddr];
        uint256 paid = userRewardPerTokenPaid[tokenAddr][user];
        if (index > paid) {
            rewardsOwed[tokenAddr][user] += (IERC20(tokenAddr).balanceOf(user) * (index - paid)) / PRECISION;
            userRewardPerTokenPaid[tokenAddr][user] = index;
        }
    }

    // Called by a factory token's _update hook BEFORE balances change.
    // Only registered tokens may call it.
    function syncHolder(address from, address to) external {
        require(tokenIndex[msg.sender] > 0, "not a factory token");
        address tokenAddr = msg.sender;
        if (from != address(0) && from != address(this) && from != DEAD) _updateReward(tokenAddr, from);
        if (to != address(0) && to != address(this) && to != DEAD) _updateReward(tokenAddr, to);
    }

    function claimHolderRewards(address tokenAddr) external {
        require(tokenIndex[tokenAddr] > 0, "unknown token");
        _updateReward(tokenAddr, msg.sender);
        uint256 amount = rewardsOwed[tokenAddr][msg.sender];
        require(amount > 0, "nothing owed");
        rewardsOwed[tokenAddr][msg.sender] = 0;
        payable(msg.sender).transfer(amount);
        emit HolderRewardClaimed(tokenAddr, msg.sender, amount);
    }

    function _antiSnipe(address tokenAddr, address buyer, uint256 amount) internal {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        if (block.timestamp <= t.creationTime + ANTI_SNIPE_WINDOW) {
            boughtInWindowOf[tokenAddr][buyer] += amount;
            require(boughtInWindowOf[tokenAddr][buyer] <= ANTI_SNIPE_CAP, "anti-snipe cap");
        }
    }

    // Shared market/limit/buyback buy settlement. `total` is the funding
    // cap (msg.value for market buys, escrow for limit buys, budget for
    // buybacks). Caller handles refunds (market/limit) or accrual
    // deduction (buyback) — this function never moves escrow/accrual.
    function _executeBuy(address tokenAddr, uint256 amount, address buyer, uint256 total, bool isBuyback) internal {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        require(t.sold + amount <= CURVE_SUPPLY, "curve sold out");
        uint256 cost = buyCost(tokenAddr, amount);
        uint256 fee = (cost * FEE_BPS) / 10000;
        require(cost + fee <= total, "underfunded");
        t.sold += amount;
        if (!isBuyback) {
            t.hypeRaised += cost;
            _antiSnipe(tokenAddr, buyer, amount);
        }
        _payFee(tokenAddr, buyer, fee);
        address to = isBuyback ? DEAD : buyer;
        require(IERC20(tokenAddr).transfer(to, amount), "transfer failed");
        if (t.hypeRaised >= GRADUATION_HYPE && !t.graduated) {
            t.graduated = true;
            emit Graduated(tokenAddr, t.hypeRaised);
        }
        if (isBuyback) {
            emit BuybackBurned(tokenAddr, amount, cost, fee);
        } else {
            emit Bought(tokenAddr, buyer, total, amount);
        }
    }

    // maxTotal is the slippage guard: revert if another trade moved the
    // price so the total exceeds what the user approved.
    function buy(address tokenAddr, uint256 amount, uint256 maxTotal) external payable {
        require(amount > 0, "zero amount");
        uint256 cost = buyCost(tokenAddr, amount);
        uint256 fee = (cost * FEE_BPS) / 10000;
        require(cost + fee <= maxTotal, "slippage exceeded");
        _executeBuy(tokenAddr, amount, msg.sender, msg.value, false);
        if (msg.value > cost + fee) payable(msg.sender).transfer(msg.value - (cost + fee));
    }

    function sell(address tokenAddr, uint256 amount, uint256 minNet) external {
        require(amount > 0, "zero amount");
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        // NOTE (v5 change): graduation no longer halts trading.
        require(amount <= t.sold, "sell more than sold");
        uint256 gross = sellRevenue(tokenAddr, amount);
        uint256 fee = (gross * FEE_BPS) / 10000;
        uint256 net = gross - fee;
        require(net >= minNet, "slippage exceeded");
        require(address(this).balance >= net, "low liquidity");
        require(IERC20(tokenAddr).transferFrom(msg.sender, address(this), amount), "transfer failed");
        t.sold -= amount;
        t.hypeRaised = t.hypeRaised >= net ? t.hypeRaised - net : 0;
        _payFee(tokenAddr, msg.sender, fee);
        payable(msg.sender).transfer(net);
        emit Sold(tokenAddr, msg.sender, amount, net);
    }

    // ---- Limit orders (on-chain escrow, whole-fill only) ----

    function placeLimitBuy(address tokenAddr, uint256 amount, uint256 maxPrice) external payable returns (uint256) {
        require(tokenIndex[tokenAddr] > 0, "unknown token");
        require(amount > 0, "zero amount");
        require(maxPrice > 0, "zero price");
        // Escrow must cover the worst case (execution at maxPrice + fee).
        uint256 maxTotal = ((maxPrice * amount) / ONE * 102) / 100;
        require(msg.value >= maxTotal, "escrow below max total");
        require(msg.value >= MIN_BUY_ORDER_HYPE, "order too small");
        uint256 id = nextOrderId++;
        orders[id] = Order({token: tokenAddr, owner: msg.sender, isBuy: true, amount: amount, price: maxPrice, escrow: msg.value, tokenEscrow: 0, active: true});
        orderIdsByToken[tokenAddr].push(id);
        emit LimitOrderPlaced(id, tokenAddr, msg.sender, true, amount, maxPrice);
        return id;
    }

    function placeLimitSell(address tokenAddr, uint256 amount, uint256 minPrice) external returns (uint256) {
        require(tokenIndex[tokenAddr] > 0, "unknown token");
        require(amount >= MIN_SELL_ORDER_TOKENS, "order too small");
        require(minPrice > 0, "zero price");
        require(IERC20(tokenAddr).transferFrom(msg.sender, address(this), amount), "transfer failed");
        uint256 id = nextOrderId++;
        orders[id] = Order({token: tokenAddr, owner: msg.sender, isBuy: false, amount: amount, price: minPrice, escrow: 0, tokenEscrow: amount, active: true});
        orderIdsByToken[tokenAddr].push(id);
        emit LimitOrderPlaced(id, tokenAddr, msg.sender, false, amount, minPrice);
        return id;
    }

    function executeLimitOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.active, "order not active");
        address tokenAddr = o.token;
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        if (o.isBuy) {
            // Average execution price must be at or below the max.
            uint256 avg = (buyCost(tokenAddr, o.amount) * ONE) / o.amount;
            require(avg <= o.price, "price above max");
            uint256 cost = buyCost(tokenAddr, o.amount);
            uint256 fee = (cost * FEE_BPS) / 10000;
            require(o.escrow >= cost + fee, "escrow short");
            o.active = false;
            _executeBuy(tokenAddr, o.amount, o.owner, o.escrow, false);
            if (o.escrow > cost + fee) payable(o.owner).transfer(o.escrow - (cost + fee));
        } else {
            uint256 avg = (sellRevenue(tokenAddr, o.amount) * ONE) / o.amount;
            require(avg >= o.price, "price below min");
            uint256 gross = sellRevenue(tokenAddr, o.amount);
            uint256 fee = (gross * FEE_BPS) / 10000;
            uint256 net = gross - fee;
            require(address(this).balance >= net, "low liquidity");
            o.active = false;
            // Escrowed tokens are already in the factory; the sale just
            // moves them from circulating (sold) back to inventory.
            t.sold -= o.amount;
            t.hypeRaised = t.hypeRaised >= net ? t.hypeRaised - net : 0;
            _payFee(tokenAddr, o.owner, fee);
            payable(o.owner).transfer(net);
            emit Sold(tokenAddr, o.owner, o.amount, net);
        }
        emit LimitOrderExecuted(orderId, tokenAddr, o.owner, o.isBuy, o.amount);
    }

    function cancelLimitOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.active, "order not active");
        require(o.owner == msg.sender, "not order owner");
        o.active = false;
        if (o.isBuy) {
            uint256 escrow = o.escrow;
            o.escrow = 0;
            if (escrow > 0) payable(msg.sender).transfer(escrow);
        } else {
            uint256 amount = o.tokenEscrow;
            o.tokenEscrow = 0;
            if (amount > 0) require(IERC20(o.token).transfer(msg.sender, amount), "transfer failed");
        }
        emit LimitOrderCancelled(orderId, o.token, msg.sender);
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function ordersFor(address tokenAddr) external view returns (uint256[] memory) {
        return orderIdsByToken[tokenAddr];
    }

    // ---- Buyback-and-burn (self-buy; see header notes) ----

    function buybackAndBurn(address tokenAddr) external {
        require(tokenIndex[tokenAddr] > 0, "unknown token");
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        uint256 budget = treasuryAccrued[tokenAddr] / 2; // 50% per call
        require(budget > 0, "no treasury accrued");
        uint256 hi = CURVE_SUPPLY - t.sold;
        require(hi > 0, "curve sold out");
        // Binary search on total cost (cost + fee), monotonic in amount.
        uint256 lo = 0;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 c = buyCost(tokenAddr, mid);
            uint256 f = (c * FEE_BPS) / 10000;
            if (c + f <= budget) lo = mid;
            else hi = mid - 1;
        }
        uint256 amount = lo;
        require(amount > 0, "treasury too small");
        uint256 cost = buyCost(tokenAddr, amount);
        uint256 fee = (cost * FEE_BPS) / 10000;
        treasuryAccrued[tokenAddr] -= (cost + fee);
        _executeBuy(tokenAddr, amount, address(this), budget, true);
    }

    function migrate(address tokenAddr) external onlyOwner {
        TokenInfo storage t = tokens[tokenIndex[tokenAddr] - 1];
        require(t.graduated, "not graduated");
        require(!t.migrated, "already migrated");
        require(dexRouter != address(0), "router not set");
        uint256 tokensLocked = IERC20(tokenAddr).balanceOf(address(this));
        uint256 hypeLocked = address(this).balance;
        t.migrated = true;
        emit Migrated(tokenAddr, tokensLocked, hypeLocked);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}
