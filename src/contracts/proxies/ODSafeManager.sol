// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {SAFEHandler} from '@contracts/proxies/SAFEHandler.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {ILiquidationEngine} from '@interfaces/ILiquidationEngine.sol';
import {IVault721} from '@interfaces/proxies/IVault721.sol';
import {ITaxCollector} from '@interfaces/ITaxCollector.sol';

import {Math} from '@libraries/Math.sol';
import {EnumerableSet} from '@openzeppelin/utils/structs/EnumerableSet.sol';
import {Assertions} from '@libraries/Assertions.sol';

import {IODSafeManager} from '@interfaces/proxies/IODSafeManager.sol';

/**
 * @title  ODSafeManager
 * @notice This contract acts as interface to the SAFEEngine, facilitating the management of SAFEs
 * @dev    This contract is meant to be used by users that interact with the protocol through a proxy contract
 */
contract ODSafeManager is IODSafeManager {
  using Math for uint256;
  using EnumerableSet for EnumerableSet.UintSet;
  using Assertions for address;

  /// @inheritdoc IODSafeManager
  address public safeEngine;

  // --- ERC721 ---
  IVault721 public vault721;

  address public taxCollector;

  uint256 internal _safeId; // Auto incremental
  mapping(address _safeOwner => EnumerableSet.UintSet) private _usrSafes;
  /// @notice Mapping of user addresses to their enumerable set of safes per collateral type
  mapping(address _safeOwner => mapping(bytes32 _cType => EnumerableSet.UintSet)) private _usrSafesPerCollat;
  /// @notice Mapping of safe ids to their data
  mapping(uint256 _safeId => SAFEData) internal _safeData;

  /// @inheritdoc IODSafeManager
  mapping(
    address _owner => mapping(uint256 _safeId => mapping(uint96 _safeNonce => mapping(address _caller => bool _ok)))
  ) public safeCan;
  /// @inheritdoc IODSafeManager
  mapping(address _safeHandler => uint256 _safeId) public safeHandlerToSafeId;

  // --- Modifiers ---

  /**
   * @notice Checks if the sender is the owner of the safe or the safe has permissions to call the function
   * @param  _safe Id of the safe to check if msg.sender has permissions for
   */
  modifier safeAllowed(uint256 _safe) {
    SAFEData memory data = _safeData[_safe];
    address owner = data.owner;
    if (msg.sender != owner && !safeCan[owner][_safe][data.nonce][msg.sender]) revert SafeNotAllowed();
    _;
  }

  /**
   * @notice Checks if the sender is the owner of the safe
   * @param  _safe Id of the safe to check if msg.sender has permissions for
   */
  modifier onlySafeOwner(uint256 _safe) {
    if (msg.sender != _safeData[_safe].owner) revert OnlySafeOwner();
    _;
  }

  constructor(address _safeEngine, address _vault721, address _taxCollector) {
    safeEngine = _safeEngine.assertNonNull();
    vault721 = IVault721(_vault721);
    vault721.initializeManager();
    taxCollector = _taxCollector.assertNonNull();
  }

  // --- Getters ---

  /// @inheritdoc IODSafeManager
  function getSafes(address _usr) external view returns (uint256[] memory _safes) {
    _safes = _usrSafes[_usr].values();
  }

  /// @inheritdoc IODSafeManager
  function getSafes(address _usr, bytes32 _cType) external view returns (uint256[] memory _safes) {
    _safes = _usrSafesPerCollat[_usr][_cType].values();
  }

  /// @inheritdoc IODSafeManager
  function getSafesData(address _usr)
    external
    view
    returns (uint256[] memory _safes, address[] memory _safeHandlers, bytes32[] memory _cTypes)
  {
    _safes = _usrSafes[_usr].values();
    _safeHandlers = new address[](_safes.length);
    _cTypes = new bytes32[](_safes.length);
    for (uint256 _i; _i < _safes.length; _i++) {
      _safeHandlers[_i] = _safeData[_safes[_i]].safeHandler;
      _cTypes[_i] = _safeData[_safes[_i]].collateralType;
    }
  }

  /// @inheritdoc IODSafeManager
  function getSafeDataFromHandler(address _handler) public view returns (SAFEData memory _sData) {
    _sData = _safeData[safeHandlerToSafeId[_handler]];
  }

  /// @inheritdoc IODSafeManager
  function safeData(uint256 _safe) external view returns (SAFEData memory _sData) {
    _sData = _safeData[_safe];
  }

  // --- Methods ---

  /// @inheritdoc IODSafeManager
  function allowSAFE(uint256 _safe, address _usr, bool _ok) external onlySafeOwner(_safe) {
    SAFEData memory data = _safeData[_safe];
    address owner = data.owner;
    safeCan[owner][_safe][data.nonce][_usr] = _ok;
    emit AllowSAFE(msg.sender, _safe, _usr, _ok);
  }

  /// @inheritdoc IODSafeManager
  function openSAFE(bytes32 _cType, address _usr) external returns (uint256 _id) {
    if (_usr == address(0)) revert ZeroAddress();

    ++_safeId;
    address _safeHandler = address(new SAFEHandler(safeEngine));

    _safeData[_safeId] = SAFEData({nonce: 0, owner: _usr, safeHandler: _safeHandler, collateralType: _cType});

    safeHandlerToSafeId[_safeHandler] = _safeId;

    _usrSafes[_usr].add(_safeId);
    _usrSafesPerCollat[_usr][_cType].add(_safeId);

    vault721.mint(_usr, _safeId);

    emit OpenSAFE(msg.sender, _usr, _safeId);
    return _safeId;
  }

  // Give the safe ownership to a dst address.
  function transferSAFEOwnership(uint256 _safe, address _dst) external {
    require(msg.sender == address(vault721), 'SafeMngr: Only Vault721');

    if (_dst == address(0)) revert ZeroAddress();
    SAFEData memory _sData = _safeData[_safe];
    if (_dst == _sData.owner) revert AlreadySafeOwner();

    _safeData[_safe].nonce += 1;

    _usrSafes[_sData.owner].remove(_safe);
    _usrSafesPerCollat[_sData.owner][_sData.collateralType].remove(_safe);

    _usrSafes[_dst].add(_safe);
    _usrSafesPerCollat[_dst][_sData.collateralType].add(_safe);

    _safeData[_safe].owner = _dst;

    emit TransferSAFEOwnership(msg.sender, _safe, _dst);
  }

  /// @inheritdoc IODSafeManager
  function modifySAFECollateralization(
    uint256 _safe,
    int256 _deltaCollateral,
    int256 _deltaDebt,
    bool _nonSafeHandlerAddress
  ) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    if (_deltaDebt != 0) {
      ITaxCollector(taxCollector).taxSingle(_sData.collateralType);
    }
    address collateralSource = _nonSafeHandlerAddress ? msg.sender : _sData.safeHandler;
    address debtDestination = collateralSource;
    ISAFEEngine(safeEngine).modifySAFECollateralization(
      _sData.collateralType, _sData.safeHandler, collateralSource, debtDestination, _deltaCollateral, _deltaDebt
    );

    vault721.updateVaultHashState(_safe);

    emit ModifySAFECollateralization(msg.sender, _safe, _deltaCollateral, _deltaDebt);
  }

  /// @inheritdoc IODSafeManager
  function transferCollateral(uint256 _safe, address _dst, uint256 _wad) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];

    ISAFEEngine(safeEngine).transferCollateral(_sData.collateralType, _sData.safeHandler, _dst, _wad);

    vault721.updateVaultHashState(_safe);

    emit TransferCollateral(msg.sender, _safe, _dst, _wad);
  }

  /// @inheritdoc IODSafeManager
  function transferCollateral(bytes32 _cType, uint256 _safe, address _dst, uint256 _wad) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    ISAFEEngine(safeEngine).transferCollateral(_cType, _sData.safeHandler, _dst, _wad);

    vault721.updateVaultHashState(_safe);

    emit TransferCollateral(msg.sender, _cType, _safe, _dst, _wad);
  }

  /// @inheritdoc IODSafeManager
  function transferInternalCoins(uint256 _safe, address _dst, uint256 _rad) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    ISAFEEngine(safeEngine).transferInternalCoins(_sData.safeHandler, _dst, _rad);
    emit TransferInternalCoins(msg.sender, _safe, _dst, _rad);
  }

  /// @inheritdoc IODSafeManager
  function quitSystem(uint256 _safe, address _dst) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    ISAFEEngine.SAFE memory _safeInfo = ISAFEEngine(safeEngine).safes(_sData.collateralType, _sData.safeHandler);
    int256 _deltaCollateral = _safeInfo.lockedCollateral.toInt();
    int256 _deltaDebt = _safeInfo.generatedDebt.toInt();
    ISAFEEngine(safeEngine).transferSAFECollateralAndDebt(
      _sData.collateralType, _sData.safeHandler, _dst, _deltaCollateral, _deltaDebt
    );

    vault721.updateVaultHashState(_safe);

    // Remove safe from owner's list (notice it doesn't erase safe ownership)
    _usrSafes[_sData.owner].remove(_safe);
    _usrSafesPerCollat[_sData.owner][_sData.collateralType].remove(_safe);
    emit QuitSystem(msg.sender, _safe, _dst);
  }

  /// @inheritdoc IODSafeManager
  function enterSystem(address _src, uint256 _safe) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    ISAFEEngine.SAFE memory _safeInfo = ISAFEEngine(safeEngine).safes(_sData.collateralType, _src);
    int256 _deltaCollateral = _safeInfo.lockedCollateral.toInt();
    int256 _deltaDebt = _safeInfo.generatedDebt.toInt();
    ISAFEEngine(safeEngine).transferSAFECollateralAndDebt(
      _sData.collateralType, _src, _sData.safeHandler, _deltaCollateral, _deltaDebt
    );

    vault721.updateVaultHashState(_safe);

    emit EnterSystem(msg.sender, _src, _safe);
  }

  /// @inheritdoc IODSafeManager
  function moveSAFE(uint256 _safeSrc, uint256 _safeDst) external safeAllowed(_safeSrc) safeAllowed(_safeDst) {
    SAFEData memory _srcData = _safeData[_safeSrc];
    SAFEData memory _dstData = _safeData[_safeDst];
    if (_srcData.collateralType != _dstData.collateralType) revert CollateralTypesMismatch();
    ISAFEEngine.SAFE memory _safeInfo = ISAFEEngine(safeEngine).safes(_srcData.collateralType, _srcData.safeHandler);
    int256 _deltaCollateral = _safeInfo.lockedCollateral.toInt();
    int256 _deltaDebt = _safeInfo.generatedDebt.toInt();
    ISAFEEngine(safeEngine).transferSAFECollateralAndDebt(
      _srcData.collateralType, _srcData.safeHandler, _dstData.safeHandler, _deltaCollateral, _deltaDebt
    );

    // @note We update the vault hash state for src and the destination as the value for both changes
    vault721.updateVaultHashState(_safeSrc);

    vault721.updateVaultHashState(_safeDst);

    // Remove safe from owner's list (notice it doesn't erase safe ownership)
    _usrSafes[_srcData.owner].remove(_safeSrc);
    _usrSafesPerCollat[_srcData.owner][_srcData.collateralType].remove(_safeSrc);
    emit MoveSAFE(msg.sender, _safeSrc, _safeDst);
  }

  /// @inheritdoc IODSafeManager
  function addSAFE(uint256 _safe) external {
    SAFEData memory _sData = _safeData[_safe];
    _usrSafes[msg.sender].add(_safe);
    _usrSafesPerCollat[msg.sender][_sData.collateralType].add(_safe);
  }

  /// @inheritdoc IODSafeManager
  function removeSAFE(uint256 _safe) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    _usrSafes[_sData.owner].remove(_safe);
    _usrSafesPerCollat[_sData.owner][_sData.collateralType].remove(_safe);
  }

  /// @inheritdoc IODSafeManager
  function protectSAFE(uint256 _safe, address _liquidationEngine, address _saviour) external safeAllowed(_safe) {
    SAFEData memory _sData = _safeData[_safe];
    ILiquidationEngine(_liquidationEngine).protectSAFE(_sData.collateralType, _sData.safeHandler, _saviour);
    emit ProtectSAFE(msg.sender, _safe, _liquidationEngine, _saviour);
  }
}
