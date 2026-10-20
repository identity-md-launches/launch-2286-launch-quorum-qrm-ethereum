// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumMembership, IERC20Local} from "./QuorumMembership.sol";
import {QuorumWork, IWorkTreasury} from "./QuorumWork.sol";
import {QuorumOperatingAccount,OperatingPlan} from "./QuorumOperatingAccount.sol";
import {QuorumCreate} from "./QuorumCreate.sol";
interface IRewardQuota {
    function rewardPaid(address recipient,uint256 amount) external;
    function openOperatingQuota(uint256 projectBudget) external;
    function closeOperatingQuota(uint256 returnedProject) external;
}

/// Two immutable assets, separate liabilities; one shared membership qualification snapshot.
contract QuorumTreasury is IWorkTreasury {
    IERC20Local public immutable asset;
    IERC20Local public immutable projectAsset;
    QuorumMembership public immutable membership;
    QuorumWork public immutable work;
    address public immutable rewardReporter;
    QuorumOperatingAccount public immutable operatingAccount;
    uint256 public operatingNative;
    event OperatingExecuted(uint256 primaryBudget,uint256 projectBudget,uint256 nativeBudget);
    struct Ledger { uint256 allowancePool; uint256 earnedAllowances; uint256 operatingFunds; uint256 reservedWork; uint256 earnedWork; }
    mapping(address => Ledger) private ledgers;
    mapping(address => mapping(uint256 => uint256)) public scheduledAsset;
    struct Week {
        bool started; bool done; uint256 cursor; uint256 rosterLimit;
        uint256 registrations; uint256 budget; uint256 perSeat;
    }
    mapping(uint256 => Week) private periods;
    mapping(uint256 => uint256) public projectBudget;
    mapping(uint256 => uint256) public projectPerSeat;
    mapping(uint256 => uint256[]) private qualifiedIds;
    mapping(uint256 => mapping(uint256 => bool)) public isQualified;
    mapping(uint256 => mapping(uint256 => bool)) public allowanceClaimed;
    bool private entered;
    bool private receivingIncome;
    bool private operatingExecution;
    modifier nonReentrant() { require(!entered && !receivingIncome,"busy");entered=true;_;entered=false; }
    // An approved operation may generate atomic tax/fee income. All outward money
    // paths remain under the execution lock, and income transfers cannot nest.
    modifier incomeReceipt() {
        require(!receivingIncome && (!entered || operatingExecution),"busy");
        receivingIncome=true;_;receivingIncome=false;
    }
    modifier onlyWork() { require(msg.sender==address(work),"work");_; }
    event Income(address indexed from,uint256 amount,uint256 scheduledWeek,uint256 allowancePart);
    event AssetIncome(address indexed asset,address indexed from,uint256 amount,uint256 scheduledWeek,uint256 allowancePart);
    event WeekSettled(uint256 indexed week,uint256 registrations,uint256 qualified,uint256 perSeat,uint256 carryWeek,uint256 carryAmount);
    event AssetWeekSettled(address indexed asset,uint256 indexed week,uint256 perSeat,uint256 carryWeek,uint256 carryAmount);
    event AllowancePaid(uint256 indexed week,uint256 indexed enrollment,address recipient,uint256 amount);
    event AssetAllowancePaid(address indexed asset,uint256 indexed week,uint256 indexed enrollment,address recipient,uint256 amount);
    constructor(IERC20Local asset_,QuorumMembership membership_,address reporter,address /* legacy unused creation reference */) {
        require(address(asset_)!=address(0) && address(asset_)!=address(membership_.token()),"distinct assets");
        asset=asset_;projectAsset=membership_.token();membership=membership_;rewardReporter=reporter;
        work=new QuorumWork(membership_,IWorkTreasury(address(this)));
        operatingAccount=new QuorumOperatingAccount(address(asset_),address(projectAsset));
    }
    function primaryAsset() external view returns(address) { return address(asset); }
    function supportsAsset(address a) public view returns(bool) { return a==address(asset) || a==address(projectAsset); }
    function ledger(address a) external view returns(Ledger memory) { require(supportsAsset(a),"asset");return ledgers[a]; }
    // Primary-asset convenience views retain the original operator interface.
    function allowancePool() external view returns(uint256) { return ledgers[address(asset)].allowancePool; }
    function earnedAllowances() external view returns(uint256) { return ledgers[address(asset)].earnedAllowances; }
    function operatingFunds() external view returns(uint256) { return ledgers[address(asset)].operatingFunds; }
    function reservedWork() external view returns(uint256) { return ledgers[address(asset)].reservedWork; }
    function earnedWork() external view returns(uint256) { return ledgers[address(asset)].earnedWork; }
    function scheduled(uint256 week) external view returns(uint256) { return scheduledAsset[address(asset)][week]; }
    function accountedAssetBalance(address a) public view returns(uint256) {
        Ledger storage l=ledgers[a];return l.allowancePool+l.earnedAllowances+l.operatingFunds+l.reservedWork+l.earnedWork;
    }
    function accountedBalance() external view returns(uint256) { return accountedAssetBalance(address(asset)); }
    function depositRevenue(uint256 amount) external incomeReceipt { _deposit(address(asset),amount); }
    function depositAssetRevenue(address a,uint256 amount) external incomeReceipt { _deposit(a,amount); }
    function _deposit(address a,uint256 amount) private {
        require(supportsAsset(a) && amount>0,"income asset/amount");
        uint256 beforeBalance=IERC20Local(a).balanceOf(address(this));
        require(IERC20Local(a).transferFrom(msg.sender,address(this),amount),"income");
        require(IERC20Local(a).balanceOf(address(this))-beforeBalance==amount,"exact receipt");
        _recordIncome(a,amount);
    }
    function _recordIncome(address a,uint256 amount) private {
        uint256 half=amount/2;uint256 target=membership.currentWeek()+1;Ledger storage l=ledgers[a];
        l.allowancePool+=half;l.operatingFunds+=amount-half;scheduledAsset[a][target]+=half;
        emit AssetIncome(a,msg.sender,amount,target,half);
        if(a==address(asset))emit Income(msg.sender,amount,target,half);
    }
    /// Direct supported-token transfers are income only after explicit recognition.
    function syncAssetRevenue(address a) external nonReentrant {
        require(supportsAsset(a),"asset");_syncAsset(a);
    }
    function _syncAsset(address a) private {
        uint256 balance=IERC20Local(a).balanceOf(address(this));uint256 accounted=accountedAssetBalance(a);
        require(balance>=accounted,"liability balance");
        if(balance>accounted)_recordIncome(a,balance-accounted);
    }
    function syncOperatingRevenue() external nonReentrant { _syncOperating(); }
    function _syncOperating() private {
        operatingAccount.sweepBeforeOperation();
        _syncAsset(address(asset));_syncAsset(address(projectAsset));
    }
    function weekInfo(uint256 week) external view returns(Week memory) { return periods[week]; }
    function settled(uint256 week) external view returns(bool) { return periods[week].done; }
    function qualifiedCount(uint256 week) external view returns(uint256) { return qualifiedIds[week].length; }
    function qualifiedEntry(uint256 week,uint256 index) external view returns(uint256) { return qualifiedIds[week][index]; }
    function settleWeek(uint256 week,uint256 limit) external {
        require(week<membership.currentWeek() && limit>0 && limit<=32,"closed week/batch");
        Week storage w=periods[week];require(!w.done,"settled");
        if(!w.started){
            w.started=true;w.rosterLimit=membership.responderCount(week);w.registrations=membership.registrationCount(week);w.budget=scheduledAsset[address(asset)][week];
            projectBudget[week]=scheduledAsset[address(projectAsset)][week];
        }
        uint256 end=w.cursor+limit;if(end>w.rosterLimit)end=w.rosterLimit;
        for(uint256 index=w.cursor;index<end;++index){
            uint256 id=membership.responderAt(week,index);
            if(membership.qualified(id,week)){qualifiedIds[week].push(id);isQualified[week][id]=true;}
        }
        w.cursor=end;
        if(end==w.rosterLimit){
            w.done=true;uint256 target=membership.currentWeek()+1;uint256 count=qualifiedIds[week].length;
            w.perSeat=_finish(address(asset),week,w.budget,w.registrations,count,target);
            projectPerSeat[week]=_finish(address(projectAsset),week,projectBudget[week],w.registrations,count,target);
            emit WeekSettled(week,w.registrations,count,w.perSeat,target,w.budget-w.perSeat*count);
        }
    }
    function _finish(address a,uint256 week,uint256 budget,uint256 registrations,uint256 count,uint256 target)
        private returns(uint256 perSeat)
    {
        perSeat=registrations==0?0:budget/registrations;uint256 earned=perSeat*count;
        Ledger storage l=ledgers[a];l.allowancePool-=earned;l.earnedAllowances+=earned;
        uint256 carry=budget-earned;scheduledAsset[a][week]=0;scheduledAsset[a][target]+=carry;
        emit AssetWeekSettled(a,week,perSeat,target,carry);
    }
    function claimAllowance(uint256 week,uint256 id) external nonReentrant {
        Week storage w=periods[week];require(w.done && isQualified[week][id] && !allowanceClaimed[week][id],"claim");
        allowanceClaimed[week][id]=true;address recipient=membership.enrollment(id).owner;
        _allowance(address(asset),week,id,recipient,w.perSeat);
        _allowance(address(projectAsset),week,id,recipient,projectPerSeat[week]);
        emit AllowancePaid(week,id,recipient,w.perSeat);
    }
    function _allowance(address a,uint256 week,uint256 id,address recipient,uint256 amount) private {
        ledgers[a].earnedAllowances-=amount;_pay(a,recipient,amount);
        emit AssetAllowancePaid(a,week,id,recipient,amount);
    }
    function reserve(address a,uint256 amount) external onlyWork {
        require(supportsAsset(a),"asset");Ledger storage l=ledgers[a];
        require(l.operatingFunds>=amount,"operating balance");l.operatingFunds-=amount;l.reservedWork+=amount;
    }
    function makePayable(address a,uint256 amount) external onlyWork { Ledger storage l=ledgers[a];l.reservedWork-=amount;l.earnedWork+=amount; }
    function pay(address a,address recipient,uint256 amount) external onlyWork nonReentrant { ledgers[a].earnedWork-=amount;_pay(a,recipient,amount); }
    function _pay(address a,address recipient,uint256 amount) private {
        if(amount==0)return;
        require(IERC20Local(a).transfer(recipient,amount),"pay");
        if(a==address(projectAsset) && rewardReporter!=address(0))IRewardQuota(rewardReporter).rewardPaid(recipient,amount);
    }
    function release(address a,uint256 amount) external onlyWork { Ledger storage l=ledgers[a];l.reservedWork-=amount;l.operatingFunds+=amount; }
    receive() external payable {
        require(msg.sender==address(operatingAccount),"operating refund only");operatingNative+=msg.value;
    }
    /// No protected liabilities or reward quota are made available to procurement.
    function executeOperating(OperatingPlan calldata plan) external onlyWork nonReentrant {
        // Pre-existing balances are not refunds from this approved operation.
        _syncOperating();
        Ledger storage p=ledgers[address(asset)];Ledger storage q=ledgers[address(projectAsset)];
        require(p.operatingFunds>=plan.primaryBudget && q.operatingFunds>=plan.projectBudget
            && operatingNative>=plan.nativeBudget,"operating budget");
        p.operatingFunds-=plan.primaryBudget;q.operatingFunds-=plan.projectBudget;operatingNative-=plan.nativeBudget;
        if(plan.primaryBudget>0)require(asset.transfer(address(operatingAccount),plan.primaryBudget),"primary budget");
        if(plan.projectBudget>0)require(projectAsset.transfer(address(operatingAccount),plan.projectBudget),"project budget");
        if(plan.nativeBudget>0){(bool ok,)=address(operatingAccount).call{value:plan.nativeBudget}("");require(ok,"native budget");}
        if(rewardReporter!=address(0))IRewardQuota(rewardReporter).openOperatingQuota(plan.projectBudget);
        operatingExecution=true;
        (uint256 returnedPrimary,uint256 returnedProject)=operatingAccount.execute(plan);
        operatingExecution=false;
        if(rewardReporter!=address(0))IRewardQuota(rewardReporter).closeOperatingQuota(returnedProject);
        // Only explicit account refunds/proceeds return to operations. Tax/fees
        // received during execution have already been split by incomeReceipt.
        p.operatingFunds+=returnedPrimary;q.operatingFunds+=returnedProject;
        emit OperatingExecuted(plan.primaryBudget,plan.projectBudget,plan.nativeBudget);
    }
}
