/// PIRawPerSecondCalculator.sol

/**
 * Reflexer PI Controller License 1.0
 *
 * Definitions
 *
 * Primary License: This license agreement
 * Secondary License: GNU General Public License v2.0 or later
 * Effective Date of Secondary License: August 1st, 2022
 *
 * Licensed Software:
 *
 * Software License Grant: Subject to and dependent upon your adherence to the terms and conditions of this Primary License, and subject to explicit approval by Reflexer, Inc., Reflexer, Inc., hereby grants you the right to copy, modify or otherwise create derivative works, redistribute, and use the Licensed Software solely for internal testing and development, and solely until the Effective Date of the Secondary License.  You may not, and you agree you will not, use the Licensed Software outside the scope of the limited license grant in this Primary License.
 *
 * You agree you will not (i) use the Licensed Software for any commercial purpose, and (ii) deploy the Licensed Software to a blockchain system other than as a noncommercial deployment to a testnet in which tokens or transactions could not reasonably be expected to have or develop commercial value.You agree to be bound by the terms and conditions of this Primary License until the Effective Date of the Secondary License, at which time the Primary License will expire and be replaced by the Secondary License. You Agree that as of the Effective Date of the Secondary License, you will be bound by the terms and conditions of the Secondary License.
 *
 * You understand and agree that any violation of the terms and conditions of this License will automatically terminate your rights under this License for the current and all other versions of the Licensed Software.
 *
 * You understand and agree that any use of the Licensed Software outside the boundaries of the limited licensed granted in this Primary License renders the license granted in this Primary License null and void as of the date you first used the Licensed Software in any way (void ab initio).You understand and agree that you may purchase a commercial license to use a version of the Licensed Software under the terms and conditions set by Reflexer, Inc.  You understand and agree that you will display an unmodified copy of this Primary License with each Licensed Software, and any derivative work of the Licensed Software.
 *
 * TO THE EXTENT PERMITTED BY APPLICABLE LAW, THE LICENSED SOFTWARE IS PROVIDED ON AN “AS IS” BASIS. REFLEXER, INC HEREBY DISCLAIMS ALL WARRANTIES AND CONDITIONS, EXPRESS OR IMPLIED, INCLUDING (WITHOUT LIMITATION) ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, AND TITLE.
 *
 * You understand and agree that all copies of the Licensed Software, and all derivative works thereof, are each subject to the terms and conditions of this License. Notwithstanding the foregoing, You hereby grant to Reflexer, Inc. a fully paid-up, worldwide, fully sublicensable license to use,for any lawful purpose, any such derivative work made by or for You, now or in the future. You agree that you will, at the request of Reflexer, Inc., provide Reflexer, Inc. with the complete source code to such derivative work.
 *
 * Copyright © 2021 Reflexer Inc. All Rights Reserved
 *
 */

pragma solidity 0.6.7;

import '../math/SafeMath.sol';
import '../math/SignedSafeMath.sol';

contract PIRawPerSecondCalculator is SafeMath, SignedSafeMath {
  // --- Authorities ---
  mapping(address => uint256) public authorities;

  function addAuthority(address account) external isAuthority {
    authorities[account] = 1;
  }

  function removeAuthority(address account) external isAuthority {
    authorities[account] = 0;
  }

  modifier isAuthority() {
    require(authorities[msg.sender] == 1, 'PIRawPerSecondCalculator/not-an-authority');
    _;
  }

  // --- Readers ---
  mapping(address => uint256) public readers;

  function addReader(address account) external isAuthority {
    readers[account] = 1;
  }

  function removeReader(address account) external isAuthority {
    readers[account] = 0;
  }

  modifier isReader() {
    require(either(allReaderToggle == 1, readers[msg.sender] == 1), 'PIRawPerSecondCalculator/not-a-reader');
    _;
  }

  // --- Structs ---
  struct ControllerGains {
    // This value is multiplied with the proportional term
    int256 Kp; // [EIGHTEEN_DECIMAL_NUMBER]
    // This value is multiplied with priceDeviationCumulative
    int256 Ki; // [EIGHTEEN_DECIMAL_NUMBER]
  }

  struct DeviationObservation {
    // The timestamp when this observation was stored
    uint256 timestamp;
    // The proportional term stored in this observation
    int256 proportional;
    // The integral term stored in this observation
    int256 integral;
  }

  // -- Static & Default Variables ---
  // The Kp and Ki values used in this calculator
  ControllerGains internal controllerGains;

  // Flag that can allow anyone to read variables
  uint256 public allReaderToggle;
  // The minimum percentage deviation from the redemption price that allows the contract to calculate a non null redemption rate
  uint256 internal noiseBarrier; // [EIGHTEEN_DECIMAL_NUMBER]
  // The default redemption rate to calculate in case P + I is smaller than noiseBarrier
  uint256 internal defaultRedemptionRate; // [TWENTY_SEVEN_DECIMAL_NUMBER]
  // The maximum value allowed for the redemption rate
  uint256 internal feedbackOutputUpperBound; // [TWENTY_SEVEN_DECIMAL_NUMBER]
  // The minimum value allowed for the redemption rate
  int256 internal feedbackOutputLowerBound; // [TWENTY_SEVEN_DECIMAL_NUMBER]
  // The minimum delay between two computeRate calls
  uint256 internal integralPeriodSize; // [seconds]

  // --- Fluctuating/Dynamic Variables ---
  // Array of observations storing the latest timestamp as well as the proportional and integral terms
  DeviationObservation[] internal deviationObservations;
  // Array of historical priceDeviationCumulative
  int256[] internal historicalCumulativeDeviations;

  // The integral term (sum of deviations at each calculateRate call minus the leak applied at every call)
  int256 internal priceDeviationCumulative; // [TWENTY_SEVEN_DECIMAL_NUMBER]
  // The per second leak applied to priceDeviationCumulative before the latest deviation is added
  uint256 internal perSecondCumulativeLeak; // [TWENTY_SEVEN_DECIMAL_NUMBER]
  // Timestamp of the last update
  uint256 internal lastUpdateTime; // [timestamp]
  // Flag indicating that the rate computed is per second
  uint256 internal constant defaultGlobalTimeline = 1;

  // The address allowed to call calculateRate
  address public seedProposer;

  uint256 internal constant NEGATIVE_RATE_LIMIT = TWENTY_SEVEN_DECIMAL_NUMBER - 1;
  uint256 internal constant TWENTY_SEVEN_DECIMAL_NUMBER = 10 ** 27;
  uint256 internal constant EIGHTEEN_DECIMAL_NUMBER = 10 ** 18;

  constructor(
    int256 Kp_,
    int256 Ki_,
    uint256 perSecondCumulativeLeak_,
    uint256 integralPeriodSize_,
    uint256 noiseBarrier_,
    uint256 feedbackOutputUpperBound_,
    int256 feedbackOutputLowerBound_,
    int256[] memory importedState
  ) public {
    defaultRedemptionRate = TWENTY_SEVEN_DECIMAL_NUMBER;

    require(
      both(
        feedbackOutputUpperBound_ < subtract(subtract(uint256(-1), defaultRedemptionRate), 1),
        feedbackOutputUpperBound_ > 0
      ),
      'PIRawPerSecondCalculator/invalid-foub'
    );
    require(
      both(feedbackOutputLowerBound_ < 0, feedbackOutputLowerBound_ >= -int256(NEGATIVE_RATE_LIMIT)),
      'PIRawPerSecondCalculator/invalid-folb'
    );
    require(integralPeriodSize_ > 0, 'PIRawPerSecondCalculator/invalid-ips');
    require(uint256(importedState[0]) <= now, 'PIRawPerSecondCalculator/invalid-imported-time');
    require(both(noiseBarrier_ > 0, noiseBarrier_ <= EIGHTEEN_DECIMAL_NUMBER), 'PIRawPerSecondCalculator/invalid-nb');
    require(
      both(Kp_ >= -int256(EIGHTEEN_DECIMAL_NUMBER), Kp_ <= int256(EIGHTEEN_DECIMAL_NUMBER)),
      'PIRawPerSecondCalculator/invalid-sg'
    );
    require(
      both(Ki_ >= -int256(EIGHTEEN_DECIMAL_NUMBER), Ki_ <= int256(EIGHTEEN_DECIMAL_NUMBER)),
      'PIRawPerSecondCalculator/invalid-ag'
    );

    authorities[msg.sender] = 1;
    readers[msg.sender] = 1;

    feedbackOutputUpperBound = feedbackOutputUpperBound_;
    feedbackOutputLowerBound = feedbackOutputLowerBound_;
    integralPeriodSize = integralPeriodSize_;
    controllerGains = ControllerGains(Kp_, Ki_);
    perSecondCumulativeLeak = perSecondCumulativeLeak_;
    priceDeviationCumulative = importedState[3];
    noiseBarrier = noiseBarrier_;
    lastUpdateTime = uint256(importedState[0]);

    if (importedState[4] > 0) {
      deviationObservations.push(DeviationObservation(uint256(importedState[4]), importedState[1], importedState[2]));
    }

    historicalCumulativeDeviations.push(priceDeviationCumulative);
  }

  // --- Boolean Logic ---
  function both(bool x, bool y) internal pure returns (bool z) {
    assembly {
      z := and(x, y)
    }
  }

  function either(bool x, bool y) internal pure returns (bool z) {
    assembly {
      z := or(x, y)
    }
  }

  // --- Administration ---
  /*
    * @notify Modify an address parameter
    * @param parameter The name of the address parameter to change
    * @param addr The new address for the parameter
    */
  function modifyParameters(bytes32 parameter, address addr) external isAuthority {
    if (parameter == 'seedProposer') {
      readers[seedProposer] = 0;
      seedProposer = addr;
      readers[seedProposer] = 1;
    } else {
      revert('PIRawPerSecondCalculator/modify-unrecognized-param');
    }
  }
  /*
    * @notify Modify an uint256 parameter
    * @param parameter The name of the parameter to change
    * @param val The new value for the parameter
    */

  function modifyParameters(bytes32 parameter, uint256 val) external isAuthority {
    if (parameter == 'nb') {
      require(both(val > 0, val <= EIGHTEEN_DECIMAL_NUMBER), 'PIRawPerSecondCalculator/invalid-nb');
      noiseBarrier = val;
    } else if (parameter == 'ips') {
      require(val > 0, 'PIRawPerSecondCalculator/null-ips');
      integralPeriodSize = val;
    } else if (parameter == 'foub') {
      require(
        both(val < subtract(subtract(uint256(-1), defaultRedemptionRate), 1), val > 0),
        'PIRawPerSecondCalculator/invalid-foub'
      );
      feedbackOutputUpperBound = val;
    } else if (parameter == 'pscl') {
      require(val <= TWENTY_SEVEN_DECIMAL_NUMBER, 'PIRawPerSecondCalculator/invalid-pscl');
      perSecondCumulativeLeak = val;
    } else if (parameter == 'allReaderToggle') {
      allReaderToggle = val;
    } else {
      revert('PIRawPerSecondCalculator/modify-unrecognized-param');
    }
  }
  /*
    * @notify Modify an int256 parameter
    * @param parameter The name of the parameter to change
    * @param val The new value for the parameter
    */

  function modifyParameters(bytes32 parameter, int256 val) external isAuthority {
    if (parameter == 'folb') {
      require(both(val < 0, val >= -int256(NEGATIVE_RATE_LIMIT)), 'PIRawPerSecondCalculator/invalid-folb');
      feedbackOutputLowerBound = val;
    } else if (parameter == 'sg') {
      require(
        both(val >= -int256(EIGHTEEN_DECIMAL_NUMBER), val <= int256(EIGHTEEN_DECIMAL_NUMBER)),
        'PIRawPerSecondCalculator/invalid-sg'
      );
      controllerGains.Kp = val;
    } else if (parameter == 'ag') {
      require(
        both(val >= -int256(EIGHTEEN_DECIMAL_NUMBER), val <= int256(EIGHTEEN_DECIMAL_NUMBER)),
        'PIRawPerSecondCalculator/invalid-ag'
      );
      controllerGains.Ki = val;
    } else if (parameter == 'pdc') {
      require(controllerGains.Ki == 0, 'PIRawPerSecondCalculator/cannot-set-pdc');
      priceDeviationCumulative = val;
    } else {
      revert('PIRawPerSecondCalculator/modify-unrecognized-param');
    }
  }

  // --- PI Specific Math ---
  function riemannSum(int256 x, int256 y) internal pure returns (int256 z) {
    return addition(x, y) / 2;
  }

  function absolute(int256 x) internal pure returns (uint256 z) {
    z = (x < 0) ? uint256(-x) : uint256(x);
  }

  // --- PI Utils ---
  /*
    * Return the last proportional term stored in deviationObservations
    */
  function getLastProportionalTerm() public view isReader returns (int256) {
    if (oll() == 0) return 0;
    return deviationObservations[oll() - 1].proportional;
  }
  /*
    * Return the last integral term stored in deviationObservations
    */

  function getLastIntegralTerm() external view isReader returns (int256) {
    if (oll() == 0) return 0;
    return deviationObservations[oll() - 1].integral;
  }
  /*
    * @notice Return the length of deviationObservations
    */

  function oll() public view isReader returns (uint256) {
    return deviationObservations.length;
  }
  /*
    * @notice Return a redemption rate bounded by feedbackOutputLowerBound and feedbackOutputUpperBound as well as the
              timeline over which that rate will take effect
    * @param piOutput The raw redemption rate computed from the proportional and integral terms
    */

  function getBoundedRedemptionRate(int256 piOutput) public view isReader returns (uint256, uint256) {
    int256 boundedPIOutput = piOutput;
    uint256 newRedemptionRate;

    if (piOutput < feedbackOutputLowerBound) {
      boundedPIOutput = feedbackOutputLowerBound;
    } else if (piOutput > int256(feedbackOutputUpperBound)) {
      boundedPIOutput = int256(feedbackOutputUpperBound);
    }

    // newRedemptionRate cannot be lower than 10^0 (1) because of the way rpower is designed
    bool negativeOutputExceedsHundred = (boundedPIOutput < 0 && -boundedPIOutput >= int256(defaultRedemptionRate));

    // If it is smaller than 1, set it to the nagative rate limit
    if (negativeOutputExceedsHundred) {
      newRedemptionRate = NEGATIVE_RATE_LIMIT;
    } else {
      // If boundedPIOutput is lower than -int(NEGATIVE_RATE_LIMIT) set newRedemptionRate to 1
      if (boundedPIOutput < 0 && boundedPIOutput <= -int256(NEGATIVE_RATE_LIMIT)) {
        newRedemptionRate = uint256(addition(int256(defaultRedemptionRate), -int256(NEGATIVE_RATE_LIMIT)));
      } else {
        // Otherwise add defaultRedemptionRate and boundedPIOutput together
        newRedemptionRate = uint256(addition(int256(defaultRedemptionRate), boundedPIOutput));
      }
    }

    return (newRedemptionRate, defaultGlobalTimeline);
  }
  /*
    * @notice Returns whether the P + I sum exceeds the noise barrier
    * @param piSum Represents a sum between P + I
    * @param redemptionPrice The system coin redemption price
    */

  function breaksNoiseBarrier(uint256 piSum, uint256 redemptionPrice) public view isReader returns (bool) {
    uint256 deltaNoise = subtract(multiply(uint256(2), EIGHTEEN_DECIMAL_NUMBER), noiseBarrier);
    return piSum >= subtract(divide(multiply(redemptionPrice, deltaNoise), EIGHTEEN_DECIMAL_NUMBER), redemptionPrice);
  }
  /*
    * @notice Compute a new priceDeviationCumulative (integral term)
    * @param proportionalTerm The proportional term (redemptionPrice - marketPrice)
    * @param accumulatedLeak The total leak applied to priceDeviationCumulative before it is summed with the new time adjusted deviation
    */

  function getNextPriceDeviationCumulative(
    int256 proportionalTerm,
    uint256 accumulatedLeak
  ) public view isReader returns (int256, int256) {
    int256 lastProportionalTerm = getLastProportionalTerm();
    uint256 timeElapsed = (lastUpdateTime == 0) ? 0 : subtract(now, lastUpdateTime);
    int256 newTimeAdjustedDeviation = multiply(riemannSum(proportionalTerm, lastProportionalTerm), int256(timeElapsed));
    int256 leakedPriceCumulative =
      divide(multiply(int256(accumulatedLeak), priceDeviationCumulative), int256(TWENTY_SEVEN_DECIMAL_NUMBER));

    return (addition(leakedPriceCumulative, newTimeAdjustedDeviation), newTimeAdjustedDeviation);
  }
  /*
    * @notice Apply Kp to the proportional term and Ki to the integral term (by multiplication) and then sum P and I
    * @param proportionalTerm The proportional term
    * @param integralTerm The integral term
    */

  function getGainAdjustedPIOutput(int256 proportionalTerm, int256 integralTerm) public view isReader returns (int256) {
    (int256 adjustedProportional, int256 adjustedIntegral) = getGainAdjustedTerms(proportionalTerm, integralTerm);
    return addition(adjustedProportional, adjustedIntegral);
  }
  /*
    * @notice Independently return and calculate P * Kp and I * Ki
    * @param proportionalTerm The proportional term
    * @param integralTerm The integral term
    */

  function getGainAdjustedTerms(
    int256 proportionalTerm,
    int256 integralTerm
  ) public view isReader returns (int256, int256) {
    return (
      multiply(proportionalTerm, int256(controllerGains.Kp)) / int256(EIGHTEEN_DECIMAL_NUMBER),
      multiply(integralTerm, int256(controllerGains.Ki)) / int256(EIGHTEEN_DECIMAL_NUMBER)
    );
  }

  // --- Rate Validation/Calculation ---
  /*
    * @notice Compute a new redemption rate
    * @param marketPrice The system coin market price
    * @param redemptionPrice The system coin redemption price
    * @param accumulatedLeak The total leak that will be applied to priceDeviationCumulative (the integral) before the latest
    *        proportional term is added
    */
  function computeRate(
    uint256 marketPrice,
    uint256 redemptionPrice,
    uint256 accumulatedLeak
  ) external returns (uint256) {
    // Only the seed proposer can call this
    require(seedProposer == msg.sender, 'PIRawPerSecondCalculator/invalid-msg-sender');
    // Ensure that at least integralPeriodSize seconds passed since the last update or that this is the first update
    require(
      subtract(now, lastUpdateTime) >= integralPeriodSize || lastUpdateTime == 0, 'PIRawPerSecondCalculator/wait-more'
    );
    // The proportional term is just redemption - market. Market is read as having 18 decimals so we multiply by 10**9
    // in order to have 27 decimals like the redemption price
    int256 proportionalTerm = subtract(int256(redemptionPrice), multiply(int256(marketPrice), int256(10 ** 9)));
    // Update the integral term by passing the proportional (current deviation) and the total leak that will be applied to the integral
    updateDeviationHistory(proportionalTerm, accumulatedLeak);
    // Set the last update time to now
    lastUpdateTime = now;
    // Multiply P by Kp and I by Ki and then sum P & I in order to return the result
    int256 piOutput = getGainAdjustedPIOutput(proportionalTerm, priceDeviationCumulative);
    // If the P * Kp + I * Ki output breaks the noise barrier, you can recompute a non null rate. Also make sure the sum is not null
    if (breaksNoiseBarrier(absolute(piOutput), redemptionPrice) && piOutput != 0) {
      // Get the new redemption rate by taking into account the feedbackOutputUpperBound and feedbackOutputLowerBound
      (uint256 newRedemptionRate,) = getBoundedRedemptionRate(piOutput);
      return newRedemptionRate;
    } else {
      return TWENTY_SEVEN_DECIMAL_NUMBER;
    }
  }
  /*
    * @notice Push new observations in deviationObservations & historicalCumulativeDeviations while also updating priceDeviationCumulative
    * @param proportionalTerm The proportionalTerm
    * @param accumulatedLeak The total leak (similar to a negative interest rate) applied to priceDeviationCumulative before proportionalTerm is added to it
    */

  function updateDeviationHistory(int256 proportionalTerm, uint256 accumulatedLeak) internal {
    (int256 virtualDeviationCumulative,) = getNextPriceDeviationCumulative(proportionalTerm, accumulatedLeak);
    priceDeviationCumulative = virtualDeviationCumulative;
    historicalCumulativeDeviations.push(priceDeviationCumulative);
    deviationObservations.push(DeviationObservation(now, proportionalTerm, priceDeviationCumulative));
  }
  /*
    * @notice Compute and return the upcoming redemption rate
    * @param marketPrice The system coin market price
    * @param redemptionPrice The system coin redemption price
    * @param accumulatedLeak The total leak applied to priceDeviationCumulative before it is summed with the proportionalTerm
    */

  function getNextRedemptionRate(
    uint256 marketPrice,
    uint256 redemptionPrice,
    uint256 accumulatedLeak
  ) public view isReader returns (uint256, int256, int256, uint256) {
    // The proportional term is just redemption - market. Market is read as having 18 decimals so we multiply by 10**9
    // in order to have 27 decimals like the redemption price
    int256 proportionalTerm = subtract(int256(redemptionPrice), multiply(int256(marketPrice), int256(10 ** 9)));
    // Get the new integral term without updating the value of priceDeviationCumulative
    (int256 cumulativeDeviation,) = getNextPriceDeviationCumulative(proportionalTerm, accumulatedLeak);
    // Multiply P by Kp and I by Ki and then sum P & I in order to return the result
    int256 piOutput = getGainAdjustedPIOutput(proportionalTerm, cumulativeDeviation);
    // If the P * Kp + I * Ki output breaks the noise barrier, you can recompute a non null rate. Also make sure the sum is not null
    if (breaksNoiseBarrier(absolute(piOutput), redemptionPrice) && piOutput != 0) {
      // Get the new redemption rate by taking into account the feedbackOutputUpperBound and feedbackOutputLowerBound
      (uint256 newRedemptionRate, uint256 rateTimeline) = getBoundedRedemptionRate(piOutput);
      return (newRedemptionRate, proportionalTerm, cumulativeDeviation, rateTimeline);
    } else {
      return (TWENTY_SEVEN_DECIMAL_NUMBER, proportionalTerm, cumulativeDeviation, defaultGlobalTimeline);
    }
  }

  // --- Parameter Getters ---
  /*
    * @notice Get the timeline over which the computed redemption rate takes effect e.g rateTimeline = 3600 so the rate is
    *         computed over 1 hour
    */
  function rt(
    uint256 marketPrice,
    uint256 redemptionPrice,
    uint256 accumulatedLeak
  ) external view isReader returns (uint256) {
    (,,, uint256 rateTimeline) = getNextRedemptionRate(marketPrice, redemptionPrice, accumulatedLeak);
    return rateTimeline;
  }
  /*
    * @notice Return Kp
    */

  function sg() external view isReader returns (int256) {
    return controllerGains.Kp;
  }
  /*
    * @notice Return Ki
    */

  function ag() external view isReader returns (int256) {
    return controllerGains.Ki;
  }

  function nb() external view isReader returns (uint256) {
    return noiseBarrier;
  }

  function drr() external view isReader returns (uint256) {
    return defaultRedemptionRate;
  }

  function foub() external view isReader returns (uint256) {
    return feedbackOutputUpperBound;
  }

  function folb() external view isReader returns (int256) {
    return feedbackOutputLowerBound;
  }

  function ips() external view isReader returns (uint256) {
    return integralPeriodSize;
  }
  /*
    * @notice Return the data from a deviation observation
    */

  function dos(uint256 i) external view isReader returns (uint256, int256, int256) {
    return
      (deviationObservations[i].timestamp, deviationObservations[i].proportional, deviationObservations[i].integral);
  }

  function hcd(uint256 i) external view isReader returns (int256) {
    return historicalCumulativeDeviations[i];
  }

  function pdc() external view isReader returns (int256) {
    return priceDeviationCumulative;
  }

  function pscl() external view isReader returns (uint256) {
    return perSecondCumulativeLeak;
  }

  function lut() external view isReader returns (uint256) {
    return lastUpdateTime;
  }

  function dgt() external view isReader returns (uint256) {
    return defaultGlobalTimeline;
  }
  /*
    * @notice Returns the time elapsed since the last calculateRate call minus integralPeriodSize
    */

  function adat() external view isReader returns (uint256) {
    uint256 elapsed = subtract(now, lastUpdateTime);
    if (elapsed < integralPeriodSize) {
      return 0;
    }
    return subtract(elapsed, integralPeriodSize);
  }
  /*
    * @notice Returns the time elapsed since the last calculateRate call
    */

  function tlv() external view isReader returns (uint256) {
    uint256 elapsed = (lastUpdateTime == 0) ? 0 : subtract(now, lastUpdateTime);
    return elapsed;
  }
}
