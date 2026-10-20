// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Local accounting prototype ONLY, not a deployable launch or a Uniswap hook.
/// Integrators MUST implement authenticated settlement and objective weekly qualification.
/// The immutable authorities here are integration boundaries, not founder admin roles.
contract QuotaPrototype {
    address public immutable settlement;
    address public immutable eligibility;
    struct Account {
        uint256 bought;
        uint256 grant;
        uint256 soldGrant;
        uint8 qualifiedWeeks;
        bool registered;
    }
    mapping(address => Account) public accounts;
    mapping(address => uint256) public earnedRewards;
    event RewardQuota(address indexed recipient,uint256 amount);
    mapping(bytes32 => bool) public registeredEntitlements;
    mapping(address => mapping(uint256 => bool)) public countedWeeks;

    struct OrganizationBudget { uint256 parked; bool open; }
    mapping(address => OrganizationBudget) private organizationBudgets;
    event OrganizationQuotaRetired(address indexed account,uint256 amount);

    // Organization-only accounting is invoked through the fixed eligibility
    // authority. Ordinary users' transfer behavior is unchanged.
    function retireOrganizationBought(address user,uint256 amount) external {
        if(msg.sender!=eligibility)revert Unauthorized();
        if(organizationBudgets[user].open)revert Invalid();
        uint256 retired=amount<accounts[user].bought?amount:accounts[user].bought;
        accounts[user].bought-=retired;
        emit OrganizationQuotaRetired(user,retired);
    }
    function openOrganizationBudget(address user,uint256 tokenBudget) external {
        if(msg.sender!=eligibility)revert Unauthorized();
        OrganizationBudget storage b=organizationBudgets[user];
        if(b.open)revert Invalid();
        uint256 bought=accounts[user].bought;
        uint256 allocated=bought<tokenBudget?bought:tokenBudget;
        b.parked=bought-allocated;b.open=true;accounts[user].bought=allocated;
    }
    function closeOrganizationBudget(address user,uint256 returnedTokens) external {
        if(msg.sender!=eligibility)revert Unauthorized();
        OrganizationBudget memory b=organizationBudgets[user];
        if(!b.open)revert Invalid();
        // Buys add credit and sales consume it during the batch. Of what is
        // left, keep only credit backed by tokens actually returned internally.
        uint256 bought=accounts[user].bought;
        uint256 kept=bought<returnedTokens?bought:returnedTokens;
        accounts[user].bought=b.parked+kept;delete organizationBudgets[user];
        emit OrganizationQuotaRetired(user,bought-kept);
    }

    error Unauthorized();
    error Invalid();
    error Duplicate();
    error InsufficientQuota();

    constructor(address settlement_, address eligibility_) {
        if (settlement_ == address(0) || eligibility_ == address(0)) revert Invalid();
        settlement = settlement_;
        eligibility = eligibility_;
    }

    /// Adapter must verify the original entitlement; this prototype does NOT verify IMD proofs.
    function register(address user, bytes32 entitlement, uint256 grant) external {
        if (msg.sender != eligibility) revert Unauthorized();
        if (user == address(0) || entitlement == bytes32(0) || grant == 0) revert Invalid();
        if (accounts[user].registered || registeredEntitlements[entitlement]) revert Duplicate();
        accounts[user].registered = true;
        accounts[user].grant = grant;
        registeredEntitlements[entitlement] = true;
    }

    /// Must be called atomically after actual net QRM delivery to the authenticated buyer.
    function recordBuy(address user, uint256 netReceived) external {
        if (msg.sender != settlement) revert Unauthorized();
        if (user == address(0) || netReceived == 0) revert Invalid();
        accounts[user].bought += netReceived;
    }

    /// The fixed integration authority must authenticate an actual treasury payout.
    function recordEarned(address user,uint256 amount) external {
        if(msg.sender!=eligibility)revert Unauthorized();
        if(user==address(0) || amount==0)revert Invalid();
        earnedRewards[user]+=amount;emit RewardQuota(user,amount);
    }

    /// Week must have already ended. Eligibility must verify all participation obligations.
    function qualify(address user, uint256 week) external {
        if (msg.sender != eligibility) revert Unauthorized();
        Account storage a = accounts[user];
        if (!a.registered || week >= currentWeek()) revert Invalid();
        if (countedWeeks[user][week]) revert Duplicate();
        countedWeeks[user][week] = true;
        if (a.qualifiedWeeks < 8) ++a.qualifiedWeeks;
    }

    // Monday 1970-01-05 UTC is the first epoch boundary.
    function currentWeek() public view returns (uint256) {
        return block.timestamp < 4 days ? 0 : (block.timestamp - 4 days) / 7 days;
    }

    function unlocked(address user) public view returns (uint256) {
        Account storage a = accounts[user];
        if (a.qualifiedWeeks < 2) return 0;
        // Exact floor(grant * qualifiedWeeks / 8), without multiplication overflow.
        return (a.grant / 8) * a.qualifiedWeeks + ((a.grant % 8) * a.qualifiedWeeks) / 8;
    }

    function available(address user) public view returns (uint256 buy, uint256 earned) {
        Account storage a = accounts[user];
        return (a.bought, unlocked(user) - a.soldGrant + earnedRewards[user]);
    }

    /// Atomic swap rollback must restore this consumption if settlement fails.
    function consume(address user, uint256 grossSold) external {
        if (msg.sender != settlement) revert Unauthorized();
        if (grossSold == 0) revert Invalid();
        Account storage a = accounts[user];
        uint256 fromBuy = grossSold < a.bought ? grossSold : a.bought;
        uint256 remaining=grossSold-fromBuy;
        uint256 grantAvailable=unlocked(user)-a.soldGrant;
        uint256 fromGrant=remaining<grantAvailable?remaining:grantAvailable;
        uint256 fromRewards=remaining-fromGrant;
        if(fromRewards>earnedRewards[user])revert InsufficientQuota();
        a.bought-=fromBuy;a.soldGrant+=fromGrant;earnedRewards[user]-=fromRewards;
    }
}

