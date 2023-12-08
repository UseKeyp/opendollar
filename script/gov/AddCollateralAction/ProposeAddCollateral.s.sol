// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {Script} from 'forge-std/Script.sol';
import {ODGovernor} from '@contracts/gov/ODGovernor.sol';
import {IGlobalSettlement} from '@contracts/settlement/GlobalSettlement.sol';
import {ICollateralJoinFactory} from '@interfaces/factories/ICollateralJoinFactory.sol';
import {ICollateralAuctionHouseFactory} from '@interfaces/factories/ICollateralAuctionHouseFactory.sol';
import {ICollateralAuctionHouse} from '@interfaces/ICollateralAuctionHouse.sol';

/// @title ProposeAddCollateral Script
/// @author OpenDollar
/// @notice Script to propose adding a new collateral type to the system via ODGovernance
/// @dev NOTE This script requires the following env vars in the REQUIRED ENV VARS section below
/// @dev This script is used to propose adding a new collateral type to the system
/// @dev The script will propose a deployment of new CollateralJoin and CollateralAuctionHouse contracts
/// @dev The script will output a JSON file with the proposal data to be used by the QueueProposal and ExecuteAddCollateral scripts
/// @dev In the root, run: export FOUNDRY_PROFILE=governance && forge script script/gov/AddCollateralAction/ProposeAddCollateral.s.sol
contract ProposeAddCollateral is Script {
  function run() public {
    /// REQUIRED ENV VARS ///
    address governanceAddress = vm.envAddress('GOVERNANCE_ADDRESS');
    address globalSettlementAddress = vm.envAddress('GLOBAL_SETTLEMENT_ADDRESS');
    bytes32 newCType = vm.envBytes32('ADD_COLLATERAL_NEW_COLLATERAL_TYPE');
    address newCAddress = vm.envAddress('ADD_COLLATERAL_NEW_COLLATERAL_ADDRESS');
    uint256 minimumBid = vm.envUint('ADD_COLLATERAL_MINIMUM_BID');
    uint256 minDiscount = vm.envUint('ADD_COLLATERAL_MIN_DISCOUNT');
    uint256 maxDiscount = vm.envUint('ADD_COLLATERAL_MAX_DISCOUNT');
    uint256 perSecondDiscountUpdateRate = vm.envUint('ADD_COLLATERAL_PER_SECOND_DISCOUNT_UPDATE_RATE');
    /// END REQUIRED ENV VARS ///

    ODGovernor gov = ODGovernor(payable(governanceAddress));
    IGlobalSettlement globalSettlement = IGlobalSettlement(globalSettlementAddress);

    string memory stringCAddress = vm.toString(newCAddress);
    string memory stringCType = vm.toString(newCType);

    // Get target contract addresses from GlobalSettlement:
    //  - CollateralJoinFactory
    //  - CollateralAuctionHouseFactory
    address[] memory targets = new address[](2);
    {
      targets[0] = address(globalSettlement.collateralJoinFactory());
      targets[1] = address(globalSettlement.collateralAuctionHouseFactory());
    }
    // No values needed
    uint256[] memory values = new uint256[](2);
    {
      values[0] = 0;
      values[1] = 0;
    }
    // Get calldata for:
    //  - CollateralJoinFactory.deployCollateralJoin
    //  - CollateralAuctionHouseFactory.deployCollateralAuctionHouse
    bytes[] memory calldatas = new bytes[](2);
    ICollateralAuctionHouse.CollateralAuctionHouseParams memory _cahCParams = ICollateralAuctionHouse
      .CollateralAuctionHouseParams({
      minimumBid: minimumBid,
      minDiscount: minDiscount,
      maxDiscount: maxDiscount,
      perSecondDiscountUpdateRate: perSecondDiscountUpdateRate
    });
    calldatas[0] = abi.encodeWithSelector(ICollateralJoinFactory.deployCollateralJoin.selector, newCType, newCAddress);
    calldatas[1] = abi.encodeWithSelector(
      ICollateralAuctionHouseFactory.deployCollateralAuctionHouse.selector, newCType, _cahCParams
    );

    // Get the description and descriptionHash
    string memory description = 'Add collateral to the system';
    bytes32 descriptionHash = keccak256(bytes(description));

    vm.startBroadcast(vm.envUint('GOV_EXECUTOR_PK'));

    // Propose the action to add the collateral type
    uint256 propId = gov.propose(targets, values, calldatas, description);

    // Verify the proposalId is expected
    assert(propId == gov.hashProposal(targets, values, calldatas, descriptionHash));

    {
      // Build the JSON output
      string memory objectKey = 'PROPOSE_ADD_COLLATERAL_KEY';
      vm.serializeString(objectKey, 'addCollateralNewCollateralAddress', stringCAddress);
      vm.serializeString(objectKey, 'addCollateralNewCollateralType', stringCType);
      vm.serializeAddress(objectKey, 'addCollateralTargets', targets);
      vm.serializeUint(objectKey, 'addCollateralValues', values);
      vm.serializeBytes(objectKey, 'addCollateralCalldatas', calldatas);
      vm.serializeString(objectKey, 'addCollateralDescription', description);
      vm.serializeBytes32(objectKey, 'addCollateralDescriptionHash', descriptionHash);

      // Write the JSON output
      // Expected JSON output:
      // {
      //   "addCollateralCalldatas": bytes[],
      //   "addCollateralDescription": string,
      //   "addCollateralDescriptionHash": bytes32,
      //   "addCollateralTargets": address[],
      //   "addCollateralValues": uint256[]
      // }
      string memory jsonOutput = vm.serializeUint(objectKey, 'proposalId', propId);
      vm.writeJson(jsonOutput, string.concat('./gov-output/add-collateral-proposal-', stringCAddress, '.json'));
    }

    vm.stopBroadcast();
  }
}
