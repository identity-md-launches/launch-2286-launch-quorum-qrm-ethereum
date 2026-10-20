// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumMembership} from "./QuorumMembership.sol";

import {OperatingPlan} from "./QuorumOperatingAccount.sol";

interface IWorkTreasury {
    function executeOperating(OperatingPlan calldata plan) external;
    function settled(uint256 week) external view returns (bool);
    function qualifiedCount(uint256 week) external view returns (uint256);
    function qualifiedEntry(uint256 week, uint256 index) external view returns (uint256);
    function primaryAsset() external view returns(address);
    function supportsAsset(address a) external view returns(bool);
    function reserve(address a,uint256 amount) external;
    function makePayable(address a,uint256 amount) external;
    function pay(address a,address recipient, uint256 amount) external;
    function release(address a,uint256 amount) external;
}

/// @notice Integrated normal-path work governance, not an audited production release.
contract QuorumWork {
    uint256 public constant VOTING = 72 hours;
    uint256 public constant DELAY = 48 hours;
    uint256 public constant WINDOW = 7 days;
    QuorumMembership public immutable membership;
    IWorkTreasury public immutable treasury;
    uint256 public agendaRevision;
    mapping(uint256 => uint256) private revisionBlock;

    // Record the block for every agenda change. Several changes in one block
    // share a checkpoint time; the final revision is the observable block state.
    function _advanceAgenda() private {
        revisionBlock[++agendaRevision] = block.number;
    }
    function agendaRevisionAt(uint256 anchorNumber) external view returns (uint256) {
        require(anchorNumber < block.number, "confirmed agenda block");
        uint256 lo; uint256 hi = agendaRevision;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (revisionBlock[mid] <= anchorNumber) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
    uint256 public workCount;
    uint256 public ballotCount;

    enum Stage { BudgetSnapshot, BudgetVoting, Funded, AcceptanceSnapshot, AcceptanceVoting, Accepted, Paid, Expired, Repair }
    enum Action { Work, Suspension, Operation }
    struct Work {
        uint256 applicant;
        uint256 worker;
        address applicantOwner;
        address workerOwner;
        address recipient;
        uint256 budget;
        uint256 deadline;
        uint256 ballot;
        bytes32 termsHash;
        bytes32 evidenceHash;
        Stage stage;
        address paymentAsset;
        uint256 repairDeadline;
        uint256 repairs;
    }
    struct Ballot {
        uint256 week;
        uint256 cursor;
        uint256 sourceCount;
        uint256 voters;
        uint256 yes;
        uint256 started;
        bool ready;
        uint256 denominator; // Qualified, non-suspended seats before any conflict recusal.
    }
    mapping(uint256 => Action) public action;
    mapping(uint256 => address) public subject;
    mapping(uint256 => Work) private works;
    mapping(uint256 => Ballot) private ballots;
    mapping(uint256 => uint256) public decisionWeek;
    mapping(uint256 => uint256) public snapshotDeadline;
    mapping(uint256 => mapping(uint256 => bool)) public eligible;
    mapping(uint256 => mapping(uint256 => bool)) public voted;
    mapping(address => mapping(uint256 => bool)) public isSuspended;
    mapping(address => uint256) public pendingSuspensionPlusOne;
    event SuspensionProposed(uint256 indexed id,address indexed subject,string evidence);
    event SuspensionScheduled(uint256 indexed id,address indexed subject,uint256 firstWeek,uint256 untilWeek);
    event Defense(uint256 indexed id,address indexed subject,string explanation);
    mapping(uint256 => bytes32) public operatingPlanHash;
    mapping(uint256 => mapping(address => bool)) public recused;
    event OperationProposed(uint256 indexed id,bytes32 planHash,bytes plan,address[] beneficiaries,string explanation);
    event OperationExecuted(uint256 indexed id,bytes32 planHash);
    event Proposed(uint256 indexed id, uint256 applicant, uint256 worker, address recipient, uint256 budget,
        uint256 deadline, bytes32 digest, string terms);
    event PaymentAssetSelected(uint256 indexed id,address indexed asset);
    event BallotReady(uint256 indexed ballot, uint256 week, uint256 voters, uint256 denominator, uint256 started);
    event Voted(uint256 indexed ballot, uint256 indexed enrollment, bool support);
    event Funded(uint256 indexed id, uint256 amount);
    event Submitted(uint256 indexed id, uint256 ballot, bytes32 digest, string evidence);
    event Accepted(uint256 indexed id, uint256 amount);
    event Paid(uint256 indexed id, address recipient, uint256 amount);
    event Expired(uint256 indexed id, uint256 returnedAmount);
    event RepairOpened(uint256 indexed id,uint256 deadline);
    event WorkerExplanation(uint256 indexed id,bytes32 digest,string explanation);

    constructor(QuorumMembership members, IWorkTreasury funds) { membership = members; treasury = funds; }
    function work(uint256 id) external view returns (Work memory) {
        require(id < workCount, "work"); return works[id];
    }
    function ballot(uint256 id) external view returns (Ballot memory) {
        require(id < ballotCount, "ballot"); return ballots[id];
    }
    function _newBallot() private returns (uint256 id) {
        uint256 week = membership.currentWeek() - 1;
        require(treasury.settled(week), "settle preceding week");
        id = ballotCount++;
        ballots[id].week = week;
        decisionWeek[id] = membership.currentWeek();
        snapshotDeadline[id]=block.timestamp+WINDOW;
        ballots[id].sourceCount = treasury.qualifiedCount(week);
    }
    function propose(uint256 applicant, uint256 worker, address recipient, uint256 budget, uint256 deadline,
        string calldata terms) external returns (uint256 id)
    {
        return _propose(applicant,worker,recipient,treasury.primaryAsset(),budget,deadline,terms);
    }
    function proposeAsset(uint256 applicant,uint256 worker,address recipient,address paymentAsset,
        uint256 budget,uint256 deadline,string calldata terms) external returns(uint256 id)
    {
        return _propose(applicant,worker,recipient,paymentAsset,budget,deadline,terms);
    }
    function _propose(uint256 applicant,uint256 worker,address recipient,address paymentAsset,
        uint256 budget,uint256 deadline,string memory terms) private returns(uint256 id)
    {
        require(treasury.supportsAsset(paymentAsset),"payment asset");
        membership.requireAgent(applicant, msg.sender);

        require(membership.live(worker), "worker active");
        require(recipient != address(0) && budget > 0, "terms");
        require(bytes(terms).length > 0 && bytes(terms).length <= 4096, "terms length");
        require(deadline > block.timestamp + VOTING + DELAY + WINDOW, "deadline");
        id = workCount++;
        Work storage w = works[id];
        w.applicant = applicant; w.worker = worker;
        w.applicantOwner = membership.enrollment(applicant).owner;
        require(!isSuspended[w.applicantOwner][membership.currentWeek()],"suspended proposer");
        w.workerOwner = membership.enrollment(worker).owner;
        w.recipient = recipient; w.paymentAsset=paymentAsset; w.budget = budget; w.deadline = deadline; w.ballot = _newBallot();
        w.termsHash = keccak256(bytes(terms));
        _advanceAgenda();
        emit PaymentAssetSelected(id,paymentAsset);
        emit Proposed(id, applicant, worker, recipient, budget, deadline, w.termsHash, terms);
    }
    function proposeSuspension(uint256 applicant,address target,string calldata evidence) external returns(uint256 id) {
        membership.requireAgent(applicant,msg.sender);

        require(target!=address(0) && membership.currentEnrollmentPlusOne(target)>0,"member target");
        require(pendingSuspensionPlusOne[target]==0 && !isSuspended[target][membership.currentWeek()]
            && !isSuspended[target][membership.currentWeek()+1],"pending suspension");
        require(bytes(evidence).length>0 && bytes(evidence).length<=4096,"evidence");
        id=workCount++;Work storage w=works[id];w.applicant=applicant;
        w.applicantOwner=membership.enrollment(applicant).owner;
        require(!isSuspended[w.applicantOwner][membership.currentWeek()],"suspended proposer");
        w.workerOwner=target;subject[id]=target;
        action[id]=Action.Suspension;w.termsHash=keccak256(bytes(evidence));w.ballot=_newBallot();
        w.deadline=type(uint256).max;pendingSuspensionPlusOne[target]=id+1;
        _advanceAgenda();emit SuspensionProposed(id,target,evidence);
    }
    function defend(uint256 id,string calldata explanation) external {
        require(id<workCount && action[id]==Action.Suspension,"suspension");
        address target=subject[id];uint256 current=membership.currentEnrollmentPlusOne(target);
        require(msg.sender==target || (current>0 && membership.isSeatAgent(current-1,msg.sender)),"subject");
        require(bytes(explanation).length>0 && bytes(explanation).length<=4096,"explanation");
        _advanceAgenda();emit Defense(id,target,explanation);
    }
    function executeSuspension(uint256 id) external {
        require(id<workCount,"work");Work storage w=works[id];
        require(action[id]==Action.Suspension && w.stage==Stage.BudgetVoting,"suspension stage");
        _approved(w.ballot);w.stage=Stage.Paid;pendingSuspensionPlusOne[subject[id]]=0;
        uint256 first=membership.currentWeek()+1;
        for(uint256 week=first;week<first+4;++week)isSuspended[subject[id]][week]=true;
        _advanceAgenda();emit SuspensionScheduled(id,subject[id],first,first+4);
    }
    function proposeOperation(uint256 applicant,OperatingPlan calldata plan,address[] calldata beneficiaries,
        string calldata explanation) external returns(uint256 id)
    {
        membership.requireAgent(applicant,msg.sender);
        require(plan.calls.length>0 && plan.calls.length<=16 && plan.approvals.length<=16
            && beneficiaries.length<=32,"operation bounds");
        require(bytes(explanation).length>0 && bytes(explanation).length<=4096,"explanation");
        id=workCount++;Work storage w=works[id];w.applicant=applicant;
        w.applicantOwner=membership.enrollment(applicant).owner;
        require(!isSuspended[w.applicantOwner][membership.currentWeek()],"suspended proposer");
        action[id]=Action.Operation;w.ballot=_newBallot();w.deadline=type(uint256).max;
        w.termsHash=keccak256(bytes(explanation));operatingPlanHash[id]=keccak256(abi.encode(plan));
        for(uint256 i;i<beneficiaries.length;++i)recused[id][beneficiaries[i]]=true;
        for(uint256 i;i<plan.calls.length;++i)recused[id][plan.calls[i].target]=true;
        for(uint256 i;i<plan.approvals.length;++i)recused[id][plan.approvals[i].spender]=true;
        _advanceAgenda();emit OperationProposed(id,operatingPlanHash[id],abi.encode(plan),beneficiaries,explanation);
    }
    function executeOperation(uint256 id,OperatingPlan calldata plan) external {
        require(id<workCount && action[id]==Action.Operation,"operation");Work storage w=works[id];
        require(w.stage==Stage.BudgetVoting && operatingPlanHash[id]==keccak256(abi.encode(plan)),"committed operation");
        _approved(w.ballot);w.stage=Stage.Paid;treasury.executeOperating(plan);
        _advanceAgenda();emit OperationExecuted(id,operatingPlanHash[id]);
    }
    /// Bounded assembly of a historical electorate. Voting begins only when assembly is complete.
    function prepareBallot(uint256 id,uint256 limit) external {
        require(id<workCount && limit>0 && limit<=32,"batch");
        Work storage w=works[id];
        require(w.stage==Stage.BudgetSnapshot || w.stage==Stage.AcceptanceSnapshot,"snapshot stage");
        Ballot storage b=ballots[w.ballot];
        require(block.timestamp<=snapshotDeadline[w.ballot],"snapshot deadline");
        for(uint256 n; n<limit && b.cursor<b.sourceCount; ++n) this.appendEntry(id);
        if(b.cursor==b.sourceCount){
            b.ready=true;b.started=block.timestamp;
            if(w.stage==Stage.BudgetSnapshot)w.stage=Stage.BudgetVoting;
            else w.stage=Stage.AcceptanceVoting;
            emit BallotReady(w.ballot,b.week,b.voters,b.denominator,b.started);
        }
    }
    function appendEntry(uint256 id) external {
        require(msg.sender==address(this),"internal batch");
        uint256 ballotId=works[id].ballot;Ballot storage b=ballots[ballotId];
        uint256 entry=treasury.qualifiedEntry(b.week,b.cursor);++b.cursor;
        QuorumMembership.Enrollment memory e=membership.enrollment(entry);
        if(!isSuspended[e.owner][decisionWeek[ballotId]])++b.denominator;
        if(this.entryEligible(id,entry)){eligible[ballotId][entry]=true;++b.voters;}
    }
    function entryEligible(uint256 id,uint256 entry) external view returns(bool) {
        Work storage w=works[id];QuorumMembership.Enrollment memory e=membership.enrollment(entry);
        if(isSuspended[e.owner][decisionWeek[w.ballot]] || recused[id][e.owner] || recused[id][e.agent])return false;
        return e.owner!=w.applicantOwner && e.owner!=w.workerOwner && e.owner!=w.recipient && e.agent!=w.recipient;
    }
    function vote(uint256 id, uint256 qualifiedEnrollment, bool support) external {
        require(id < workCount, "work"); Work storage w = works[id]; Ballot storage b = ballots[w.ballot];
        require((w.stage == Stage.BudgetVoting || w.stage == Stage.AcceptanceVoting)
            && b.ready && block.timestamp < b.started + VOTING, "voting period");
        require(eligible[w.ballot][qualifiedEnrollment] && !voted[w.ballot][qualifiedEnrollment], "eligible");
        require(membership.isSeatAgent(qualifiedEnrollment, msg.sender), "authorized seat agent");
        voted[w.ballot][qualifiedEnrollment] = true; if (support) ++b.yes;
        emit Voted(w.ballot, qualifiedEnrollment, support);
    }
    function threshold(uint256 ballotId) public view returns (uint256) {
        require(ballotId < ballotCount, "ballot");
        Ballot storage b=ballots[ballotId];require(b.ready,"snapshot incomplete");
        return (b.denominator * 2 + 2) / 3;
    }
    function _approved(uint256 ballotId) private view {
        Ballot storage b = ballots[ballotId];
        require(b.ready && b.voters >= 5 && b.yes >= threshold(ballotId), "approval");
        require(block.timestamp >= b.started + VOTING + DELAY
            && block.timestamp <= b.started + VOTING + DELAY + WINDOW, "execution window");
    }
    function fund(uint256 id) external {
        require(id < workCount, "work"); Work storage w = works[id];
        require(action[id]==Action.Work && w.stage == Stage.BudgetVoting && block.timestamp < w.deadline, "funding stage");
        _approved(w.ballot); w.stage = Stage.Funded; treasury.reserve(w.paymentAsset,w.budget);
        _advanceAgenda(); emit Funded(id, w.budget);
    }
    function submit(uint256 id, string calldata evidence) external {
        require(id < workCount, "work"); Work storage w = works[id];
        require((w.stage == Stage.Funded && block.timestamp <= w.deadline)
            || (w.stage == Stage.Repair && block.timestamp <= w.repairDeadline), "delivery stage");
        require(membership.isSeatAgent(w.worker, msg.sender), "worker");
        require(bytes(evidence).length > 0 && bytes(evidence).length <= 4096, "evidence");
        w.evidenceHash = keccak256(bytes(evidence));
        w.ballot = _newBallot(); w.stage = Stage.AcceptanceSnapshot;
        _advanceAgenda(); emit Submitted(id, w.ballot, w.evidenceHash, evidence);
    }
    function accept(uint256 id) external {
        require(id < workCount, "work"); Work storage w = works[id];
        require(w.stage == Stage.AcceptanceVoting, "acceptance stage");
        _approved(w.ballot); w.stage = Stage.Accepted; treasury.makePayable(w.paymentAsset,w.budget);
        _advanceAgenda(); emit Accepted(id, w.budget);
    }
    function claim(uint256 id) external {
        require(id < workCount, "work"); Work storage w = works[id]; require(w.stage == Stage.Accepted, "claim stage");
        w.stage = Stage.Paid; treasury.pay(w.paymentAsset,w.recipient, w.budget); _advanceAgenda();
        emit Paid(id, w.recipient, w.budget);
    }
    /// Unsuccessful voting or unassembled electorate share the single repair opportunity.
    function resolveAcceptance(uint256 id) external {
        require(id < workCount, "work"); Work storage w = works[id];
        uint256 close;
        if(w.stage==Stage.AcceptanceSnapshot){
            close=snapshotDeadline[w.ballot];require(block.timestamp>close,"snapshot open");
        } else {
            require(w.stage==Stage.AcceptanceVoting,"acceptance stage");Ballot storage b=ballots[w.ballot];
            close=b.started+VOTING;require(block.timestamp>=close,"voting open");
            require(b.voters<5 || b.yes<threshold(w.ballot),"passed vote");
        }
        if (w.repairs == 0 && block.timestamp <= close + WINDOW) {
            w.repairs = 1; w.repairDeadline = close + WINDOW;
            w.stage = Stage.Repair; _advanceAgenda(); emit RepairOpened(id,w.repairDeadline);
        } else { _expire(id,w.budget); }
    }
    function explain(uint256 id,string calldata explanation) external {
        require(id < workCount && bytes(explanation).length > 0 && bytes(explanation).length <= 4096,"explanation");
        require(membership.isSeatAgent(works[id].worker,msg.sender) || msg.sender==works[id].workerOwner,"worker");
        emit WorkerExplanation(id,keccak256(bytes(explanation)),explanation);
        _advanceAgenda();
    }
    function _expire(uint256 id,uint256 released) private {
        Work storage w = works[id]; w.stage = Stage.Expired;
        if(action[id]==Action.Suspension)pendingSuspensionPlusOne[subject[id]]=0;
        if (released > 0) treasury.release(w.paymentAsset,released);
        _advanceAgenda(); emit Expired(id, released);
    }
    function expire(uint256 id) external {
        require(id < workCount, "work"); Work storage w = works[id];
        uint256 released;
        if(w.stage==Stage.BudgetSnapshot){
            require(block.timestamp>snapshotDeadline[w.ballot],"snapshot deadline");
        } else if(w.stage==Stage.AcceptanceSnapshot){
            require(block.timestamp>snapshotDeadline[w.ballot]+(w.repairs==0?WINDOW:0),"repair opportunity");
            released=w.budget;
        } else if (w.stage == Stage.BudgetVoting || w.stage == Stage.Funded) {
            require(block.timestamp > w.deadline || (w.stage==Stage.BudgetVoting
                && block.timestamp>ballots[w.ballot].started+VOTING+DELAY+WINDOW), "deadline");
            if (w.stage == Stage.Funded) released = w.budget;
        } else if (w.stage == Stage.Repair) {
            require(block.timestamp > w.repairDeadline,"repair deadline"); released=w.budget;
        } else {
            require(w.stage == Stage.AcceptanceVoting, "stage");
            Ballot storage b=ballots[w.ballot];
            // An unsuccessful first vote retains its full repair opportunity.
            if (b.voters < 5 || b.yes < threshold(w.ballot)) {
                require(w.repairs > 0 ? block.timestamp >= b.started + VOTING
                    : block.timestamp > b.started + VOTING + WINDOW,"repair opportunity");
            } else {
                require(block.timestamp > b.started + VOTING + DELAY + WINDOW,"window");
            }
            released = w.budget;
        }
        _expire(id,released);
    }
}
