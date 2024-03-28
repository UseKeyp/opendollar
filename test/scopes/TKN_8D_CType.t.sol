// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {Base_CType} from '@test/scopes/Base_CType.t.sol';

abstract contract TKN_8D_CType is Base_CType {
  function _cType() internal virtual override returns (bytes32) {
    return bytes32('TKN-8D');
  }
}
