// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Local {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}
interface ISeatNFT { function ownerOf(uint256 seat) external view returns (address); }
interface IAgendaSource {
    function agendaRevision() external view returns (uint256);
    function agendaRevisionAt(uint256 blockNumber) external view returns (uint256);
    function isSuspended(address seat,uint256 week) external view returns(bool);
}

/// @notice One staking address per seat; no member cap or NFT ownership prerequisite.
/// The fixed deposit is independent of the later launch distribution snapshot.
contract QuorumMembership {
    uint256 public constant WEEK = 7 days;
    uint256 public constant EPOCH = 4 days; // Monday 1970-01-05 UTC.
    uint256 public constant REQUIRED_HOURS = 126;
    IERC20Local public immutable token;
    IAgendaSource public immutable agenda;
    bytes32 public immutable constitutionHash;
    uint256 public immutable stakeAmount;
    uint256 public totalStaked;
    uint256 public enrollmentCount;
    bool private entered;

    struct Authorization { address owner; address agent; uint256 expires; uint256 nonce; }
    struct Enrollment {
        address seat;
        address owner;
        address agent;
        uint256 expires;
        uint256 nonce;
        uint256 firstWeek;
        uint256 endWeek; // First week invalid for full-week qualification.
        uint256 stake;
        uint256 exitAt;
    }
    // Prefix sums of registration intervals: cost is bounded independently of history.
    uint256 private constant WEEK_INDEX_LIMIT = 1 << 32;
    mapping(uint256 => int256) private registrationDeltas;
    mapping(uint256 => uint256[]) private weeklyResponders;
    function _delta(uint256 week, int256 change) private {
        for(uint256 i=week+1;i<WEEK_INDEX_LIMIT;i+=i & (~i+1)) registrationDeltas[i]+=change;
    }
    function _expiryWeek(uint256 expires) private pure returns(uint256) {
        // Clamp only beyond an approximately 82-million-year indexing horizon.
        if(expires>=EPOCH+(WEEK_INDEX_LIMIT-1)*WEEK) return WEEK_INDEX_LIMIT-1;
        return (expires-EPOCH)/WEEK+((expires-EPOCH)%WEEK==0?0:1);
    }
    function registrationCount(uint256 week) external view returns(uint256) {
        require(week<WEEK_INDEX_LIMIT-1,"week range");int256 count;
        for(uint256 i=week+1;i>0;i-=i & (~i+1)) count+=registrationDeltas[i];
        require(count>=0,"registration count");return uint256(count);
    }
    function responderCount(uint256 week) external view returns(uint256) {return weeklyResponders[week].length;}
    function responderAt(uint256 week,uint256 index) external view returns(uint256) {return weeklyResponders[week][index];}
    mapping(address => Authorization) public authorizations;
    mapping(uint256 => Enrollment) private entries;
    mapping(address => uint256) public currentEnrollmentPlusOne;
    mapping(uint256 => mapping(uint256 => uint256)) public hourBitmap;
    mapping(uint256 => mapping(uint256 => uint256)) public responseCount;
    mapping(uint256 => mapping(uint256 => bytes32)) public reportHash;

    event Authorized(address indexed seat, address indexed owner, address agent, uint256 expires, uint256 nonce);
    event Joined(uint256 indexed enrollment, address indexed seat, address owner, address agent, uint256 firstWeek);
    event Ended(uint256 indexed enrollment, uint256 firstInvalidWeek);
    event Responded(uint256 indexed enrollment, uint256 indexed week, uint256 hour, uint256 blockNumber,
        bytes32 blockHash, uint256 agendaRevision, string response);
    event Reported(uint256 indexed enrollment, uint256 indexed week, bytes32 digest, string report);
    event ExitRequested(uint256 indexed enrollment, uint256 availableAt);
    event Withdrawn(uint256 indexed enrollment, address indexed originalDepositor, uint256 amount);

    modifier nonReentrant() { require(!entered, "busy"); entered = true; _; entered = false; }

    constructor(IERC20Local token_, uint256 fixedStake, bytes32 constitution_, IAgendaSource agenda_) {
        require(address(token_) != address(0) && fixedStake > 0, "configuration");
        token = token_; constitutionHash = constitution_; agenda = agenda_;
        stakeAmount = fixedStake;
        require(stakeAmount > 0, "stake");
    }
    function currentWeek() public view returns (uint256) { return (block.timestamp - EPOCH) / WEEK; }
    function weekStart(uint256 week) public pure returns (uint256) { return EPOCH + week * WEEK; }
    function enrollment(uint256 id) external view returns (Enrollment memory) {
        require(id < enrollmentCount, "unknown enrollment"); return entries[id];
    }
    function live(uint256 id) public view returns (bool) {
        if (id >= enrollmentCount) return false;
        Enrollment storage e = entries[id]; Authorization storage a = authorizations[e.seat];
        return currentEnrollmentPlusOne[e.seat] == id + 1 && e.endWeek == type(uint256).max
            && e.expires > block.timestamp
            && a.nonce == e.nonce && a.agent == e.agent && a.owner == e.owner;
    }
    function isSeatAgent(uint256 historicalId, address sender) external view returns (bool) {
        if (historicalId >= enrollmentCount) return false;
        Enrollment storage old = entries[historicalId];
        uint256 current = currentEnrollmentPlusOne[old.seat];
        return current > 0 && live(current - 1) && entries[current - 1].owner == old.owner
            && entries[current - 1].agent == sender;
    }
    function requireAgent(uint256 id, address sender) external view {
        require(live(id) && entries[id].agent == sender, "live agent");
    }
    function _end(uint256 id) private {
        Enrollment storage e = entries[id];
        if (e.endWeek > currentWeek()) {
            uint256 oldExclusive=_expiryWeek(e.expires);
            uint256 newExclusive=currentWeek()+1;
            // Registration at the beginning of the current week is preserved.
            if(e.firstWeek<oldExclusive && newExclusive<oldExclusive){_delta(newExclusive,-1);_delta(oldExclusive,1);}
            e.endWeek = currentWeek(); emit Ended(id, e.endWeek);
        }
    }
    function authorize(address agent_, uint256 expires) external {
        address seat = msg.sender;
        require(agent_ != address(0) && expires > block.timestamp, "owner authorization");
        uint256 previous = currentEnrollmentPlusOne[seat];
        if (previous > 0) _end(previous - 1);
        uint256 nonce = authorizations[seat].nonce + 1;
        authorizations[seat] = Authorization(msg.sender, agent_, expires, nonce);
        emit Authorized(seat, msg.sender, agent_, expires, nonce);
    }
    function revoke() external {
        address seat = msg.sender;
        uint256 previous = currentEnrollmentPlusOne[seat];
        if (previous > 0) _end(previous - 1);
        Authorization storage a = authorizations[seat]; ++a.nonce; a.agent = address(0); a.expires = 0;
        emit Authorized(seat, msg.sender, address(0), 0, a.nonce);
    }
    function accept(address seat, uint256 nonce, bytes32 acceptedConstitution) external nonReentrant returns (uint256 id) {
        Authorization storage a = authorizations[seat];
        require(a.agent == msg.sender && a.nonce == nonce && a.expires > block.timestamp
            && seat == a.owner && acceptedConstitution == constitutionHash, "accept authorization");
        uint256 oldPlusOne = currentEnrollmentPlusOne[seat];
        bool carried;
        if (oldPlusOne > 0) {
            Enrollment storage old = entries[oldPlusOne - 1];
            require(old.nonce != nonce || old.owner != a.owner, "already accepted");
            _end(oldPlusOne - 1);
            if (old.owner == a.owner && old.stake > 0 && old.exitAt == 0) {
                old.stake = 0; carried = true;
            }
        }
        if (!carried) {
            require(token.transferFrom(a.owner, address(this), stakeAmount), "deposit");
            totalStaked += stakeAmount;
        }
        require(currentWeek()+1<WEEK_INDEX_LIMIT-1,"week range");
        uint256 first=currentWeek()+1;uint256 last=_expiryWeek(a.expires);
        if(first<last){_delta(first,1);_delta(last,-1);}
        id = enrollmentCount++;
        entries[id] = Enrollment(seat, a.owner, a.agent, a.expires, a.nonce, currentWeek() + 1,
            type(uint256).max, stakeAmount, 0);
        currentEnrollmentPlusOne[seat] = id + 1;
        emit Joined(id, seat, a.owner, a.agent, currentWeek() + 1);
    }
    function respond(uint256 id, uint256 anchorNumber, bytes32 anchorHash, uint256 revision,
        string calldata response) external
    {
        require(live(id) && entries[id].agent == msg.sender, "live agent");
        require(anchorNumber < block.number && block.number - anchorNumber <= 256
            && anchorHash != bytes32(0) && blockhash(anchorNumber) == anchorHash, "confirmed context");
        require(revision == agenda.agendaRevisionAt(anchorNumber), "anchor agenda mismatch");
        require(bytes(response).length > 0 && bytes(response).length <= 2048, "response length");
        uint256 week = currentWeek();
        uint256 hour = (block.timestamp - weekStart(week)) / 1 hours;
        uint256 bit = uint256(1) << hour;
        require(hourBitmap[id][week] & bit == 0, "hour recorded");
        if(responseCount[id][week]==0 && registeredAtStart(id,week)) weeklyResponders[week].push(id);
        hourBitmap[id][week] |= bit; ++responseCount[id][week];
        emit Responded(id, week, hour, anchorNumber, anchorHash, revision, response);
    }
    function report(uint256 id, string calldata text) external {
        require(live(id) && entries[id].agent == msg.sender, "live agent");
        require(bytes(text).length > 0 && bytes(text).length <= 2048, "report length");
        uint256 week = currentWeek(); bytes32 digest = keccak256(bytes(text));
        reportHash[id][week] = digest; // Latest report in the current week is authoritative.
        emit Reported(id, week, digest, text);
    }
    function registeredAtStart(uint256 id, uint256 week) public view returns (bool) {
        if (id >= enrollmentCount) return false;
        Enrollment storage e = entries[id];
        return e.firstWeek <= week && e.endWeek >= week && e.expires > weekStart(week);
    }
    function qualified(uint256 id, uint256 week) public view returns (bool) {
        if (id >= enrollmentCount || week >= currentWeek()) return false;
        Enrollment storage e = entries[id];
        return !agenda.isSuspended(e.owner,week) && registeredAtStart(id, week) && e.endWeek > week && e.expires >= weekStart(week + 1)
            && responseCount[id][week] >= REQUIRED_HOURS && reportHash[id][week] != bytes32(0);
    }
    function requestExit(uint256 id) external {
        require(id < enrollmentCount, "unknown enrollment");
        Enrollment storage e = entries[id];
        require(msg.sender == e.owner || (live(id) && msg.sender == e.agent), "depositor or live agent");
        require(e.stake > 0 && e.exitAt == 0, "exit state");
        _end(id); e.exitAt = block.timestamp + WEEK; emit ExitRequested(id, e.exitAt);
    }
    function withdraw(uint256 id) external nonReentrant {
        require(id < enrollmentCount, "unknown enrollment");
        Enrollment storage e = entries[id];
        require(e.exitAt > 0 && block.timestamp >= e.exitAt && e.stake > 0, "withdrawal state");
        uint256 amount = e.stake; e.stake = 0; totalStaked -= amount;
        require(token.transfer(e.owner, amount), "refund"); emit Withdrawn(id, e.owner, amount);
    }
}
