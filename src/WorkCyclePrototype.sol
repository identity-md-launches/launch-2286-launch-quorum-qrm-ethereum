// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface WorkAsset {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Local work-cycle prototype, NOT a deployable DAO.
/// @dev Uses a fixed rehearsal electorate, not NFT seats or weekly eligibility.
/// Supports a plain ERC20, positive acceptance, and expiry. Repair/disputes are not implemented.
contract WorkCyclePrototype {
    uint256 public constant VOTING_PERIOD = 72 hours;
    uint256 public constant TIMELOCK = 48 hours;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    WorkAsset public immutable asset;
    address[] private electorate;
    mapping(address => bool) public isMember;
    uint256 public allowanceFunds;
    uint256 public operatingFunds;
    uint256 public reservedFunds;
    uint256 public claimableFunds;
    uint256 public nextWorkId;
    bool private entered;

    enum Stage { Proposed, Funded, Submitted, Accepted, Paid, Expired }
    struct Work {
        address proposer;
        address worker;
        address recipient;
        uint256 budget;
        uint256 deliveryDeadline;
        uint256 proposedAt;
        uint256 submittedAt;
        uint256 eligibleCount;
        uint256 approvals;
        uint256 acceptanceApprovals;
        bytes32 specificationHash;
        bytes32 evidenceHash;
        Stage stage;
    }
    mapping(uint256 => Work) private works;
    mapping(uint256 => mapping(address => bool)) public budgetVoted;
    mapping(uint256 => mapping(address => bool)) public acceptanceVoted;

    event RevenueReceived(address indexed from, uint256 amount, uint256 allowancePart, uint256 operatingPart);
    event WorkProposed(uint256 indexed id, address indexed worker, address recipient, uint256 budget,
        uint256 deliveryDeadline, bytes32 specificationHash, string specification);
    event VoteCast(uint256 indexed id, address indexed voter, bool acceptance, bool support);
    event BudgetReserved(uint256 indexed id, uint256 amount);
    event WorkSubmitted(uint256 indexed id, bytes32 evidenceHash, string evidence);
    event WorkAccepted(uint256 indexed id, uint256 amount);
    event RewardPaid(uint256 indexed id, address indexed recipient, uint256 amount);
    event WorkExpired(uint256 indexed id, uint256 releasedBudget);

    modifier nonReentrant() {
        require(!entered, "busy"); entered = true; _; entered = false;
    }

    constructor(WorkAsset asset_, address[] memory rehearsalMembers) {
        require(address(asset_) != address(0), "asset");
        require(rehearsalMembers.length >= 6 && rehearsalMembers.length <= 128, "electorate");
        asset = asset_;
        for (uint256 i; i < rehearsalMembers.length; ++i) {
            address member = rehearsalMembers[i];
            require(member != address(0) && !isMember[member], "member");
            isMember[member] = true;
            electorate.push(member);
        }
    }

    function work(uint256 id) external view returns (Work memory) {
        require(id < nextWorkId, "unknown work"); return works[id];
    }

    function depositRevenue(uint256 amount) external nonReentrant {
        require(amount > 0, "amount");
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer");
        uint256 part = amount / 2;
        allowanceFunds += part;
        operatingFunds += amount - part;
        emit RevenueReceived(msg.sender, amount, part, amount - part);
    }

    function propose(address worker, address recipient, uint256 budget, uint256 deadline,
        string calldata specification) external returns (uint256 id)
    {
        require(isMember[msg.sender] && isMember[worker], "membership");
        require(recipient != address(0) && recipient != address(this), "recipient");
        require(budget > 0 && bytes(specification).length > 0 && bytes(specification).length <= 4096, "terms");
        require(deadline > block.timestamp + VOTING_PERIOD + TIMELOCK + EXECUTION_WINDOW, "deadline");
        id = nextWorkId++;
        Work storage w = works[id];
        w.proposer = msg.sender; w.worker = worker; w.recipient = recipient;
        w.budget = budget; w.deliveryDeadline = deadline; w.proposedAt = block.timestamp;
        w.specificationHash = keccak256(bytes(specification));
        for (uint256 i; i < electorate.length; ++i) {
            if (!_recused(w, electorate[i])) ++w.eligibleCount;
        }
        require(w.eligibleCount >= 5, "five independent seats");
        emit WorkProposed(id, worker, recipient, budget, deadline, w.specificationHash, specification);
    }

    function _recused(Work storage w, address member) private view returns (bool) {
        return member == w.proposer || member == w.worker || member == w.recipient;
    }

    function requiredApprovals(uint256 id) public view returns (uint256) {
        require(id < nextWorkId, "unknown work");
        return (works[id].eligibleCount * 2 + 2) / 3;
    }

    function vote(uint256 id, bool acceptance, bool support) external {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        require(isMember[msg.sender] && !_recused(w, msg.sender), "eligible voter");
        if (acceptance) {
            require(w.stage == Stage.Submitted, "stage");
            require(block.timestamp < w.submittedAt + VOTING_PERIOD, "vote ended");
            require(!acceptanceVoted[id][msg.sender], "already voted");
            acceptanceVoted[id][msg.sender] = true;
            if (support) ++w.acceptanceApprovals;
        } else {
            require(w.stage == Stage.Proposed, "stage");
            require(block.timestamp < w.proposedAt + VOTING_PERIOD, "vote ended");
            require(!budgetVoted[id][msg.sender], "already voted");
            budgetVoted[id][msg.sender] = true;
            if (support) ++w.approvals;
        }
        emit VoteCast(id, msg.sender, acceptance, support);
    }

    function reserveBudget(uint256 id) external {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        require(w.stage == Stage.Proposed, "stage");
        _executionWindow(w.proposedAt);
        require(w.approvals >= requiredApprovals(id), "vote threshold");
        require(operatingFunds >= w.budget, "available budget");
        operatingFunds -= w.budget; reservedFunds += w.budget;
        w.stage = Stage.Funded;
        emit BudgetReserved(id, w.budget);
    }

    function submit(uint256 id, string calldata evidence) external {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        require(w.stage == Stage.Funded && msg.sender == w.worker, "worker");
        require(block.timestamp <= w.deliveryDeadline, "delivery deadline");
        require(bytes(evidence).length > 0 && bytes(evidence).length <= 4096, "evidence");
        w.evidenceHash = keccak256(bytes(evidence)); w.submittedAt = block.timestamp;
        w.stage = Stage.Submitted;
        emit WorkSubmitted(id, w.evidenceHash, evidence);
    }

    function acceptWork(uint256 id) external {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        require(w.stage == Stage.Submitted, "stage");
        _executionWindow(w.submittedAt);
        require(w.acceptanceApprovals >= requiredApprovals(id), "vote threshold");
        reservedFunds -= w.budget; claimableFunds += w.budget;
        w.stage = Stage.Accepted;
        emit WorkAccepted(id, w.budget);
    }

    /// Anyone may relay a claim; funds always go to the original agreed recipient.
    function claim(uint256 id) external nonReentrant {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        require(w.stage == Stage.Accepted, "stage");
        w.stage = Stage.Paid; claimableFunds -= w.budget;
        require(asset.transfer(w.recipient, w.budget), "transfer");
        emit RewardPaid(id, w.recipient, w.budget);
    }

    /// Prototype expiry only; repair/rejection proceedings must be added before release.
    function expire(uint256 id) external {
        require(id < nextWorkId, "unknown work");
        Work storage w = works[id];
        uint256 released;
        if (w.stage == Stage.Proposed) {
            require(block.timestamp > w.proposedAt + VOTING_PERIOD + TIMELOCK + EXECUTION_WINDOW, "not expired");
        } else if (w.stage == Stage.Funded) {
            require(block.timestamp > w.deliveryDeadline, "not expired");
            released = w.budget;
        } else {
            require(w.stage == Stage.Submitted, "stage");
            require(block.timestamp > w.submittedAt + VOTING_PERIOD + TIMELOCK + EXECUTION_WINDOW, "not expired");
            released = w.budget;
        }
        if (released > 0) { reservedFunds -= released; operatingFunds += released; }
        w.stage = Stage.Expired;
        emit WorkExpired(id, released);
    }

    function _executionWindow(uint256 start) private view {
        uint256 readyAt = start + VOTING_PERIOD + TIMELOCK;
        require(block.timestamp >= readyAt && block.timestamp <= readyAt + EXECUTION_WINDOW, "execution window");
    }
}
