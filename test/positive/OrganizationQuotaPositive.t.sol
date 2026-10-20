// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuotaPrototype} from "../../src/QuotaPrototype.sol";
/// Normal accounting compositions; no privilege-bypass scenarios.
contract OrganizationQuotaPositiveTest {
    QuotaPrototype q;
    address constant ORG=address(0x1234);
    function setUp() public {q=new QuotaPrototype(address(this),address(this));q.recordBuy(ORG,100);}
    function bought() internal view returns(uint256 v){(v,)=q.available(ORG);}
    function testNormalUnusedBudgetPreservesCredit() public {
        q.openOrganizationBudget(ORG,30);require(bought()==30);
        q.closeOrganizationBudget(ORG,30);require(bought()==100);
    }
    function testNormalBuyAndProcurementKeepsOnlyReturnedCredit() public {
        q.openOrganizationBudget(ORG,0);q.recordBuy(ORG,50);
        q.closeOrganizationBudget(ORG,20);require(bought()==120);
    }
    function testNormalSaleConsumesCreditOnlyOnce() public {
        q.openOrganizationBudget(ORG,60);q.consume(ORG,20);
        q.closeOrganizationBudget(ORG,40);require(bought()==80);
    }
    function testNormalDonationRefundDoesNotCreateCredit() public {
        q.openOrganizationBudget(ORG,30);q.closeOrganizationBudget(ORG,80);require(bought()==100);
    }
    function testNormalRewardPayoutRetiresExistingCreditDownToZero() public {
        q.retireOrganizationBought(ORG,30);q.recordEarned(address(0x77),30);
        require(bought()==70 && q.earnedRewards(address(0x77))==30);
        q.retireOrganizationBought(ORG,100);require(bought()==0);
    }
}
