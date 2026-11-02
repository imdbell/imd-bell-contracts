// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";
import {Suite} from "./Suite.sol";
import {Stateful} from "./Stateful.sol";
import {StandInIntake, StandInBurnExecutor, StandInLaunchFees} from "./StandIns.sol";
import {RingerUnit} from "./RingerUnit.sol";
import {RingerStateful} from "./RingerStateful.sol";
import {AuditFixes} from "./AuditFixes.sol";
import {FeeRootAndCap} from "./FeeRootAndCap.sol";
import {ResidualCap} from "./ResidualCap.sol";

/// The offline environment: a local PoolManager, a stand-in IMD, a stand-in burn executor, a stand-in fee setting and
/// a stand-in Intake. Run with `forge test`; no network is needed.
abstract contract DevEnv is Base {
    function _env() internal override {
        manager = IPoolManager(address(new PoolManager(address(this))));
        // the stand-in is created with `new`; its salt is searched so it sorts high, as the real IMD does, and the
        // test coins (searched to sort below IMD) are found in a few tries
        bytes32 h = keccak256(abi.encodePacked(type(MockERC20).creationCode, abi.encode("Stand-in", "STAND", uint8(18))));
        uint256 i;
        while (_create2At(bytes32(i), h) < address(uint160(0xD0) << 152)) ++i;
        imd = address(new MockERC20{salt: bytes32(i)}("Stand-in", "STAND", 18));
        burnExecutor = address(new StandInBurnExecutor());
        launchFees = address(new StandInLaunchFees(makeAddr("network")));
        intakeWriter = makeAddr("intake writer");
        intake = address(new StandInIntake(intakeWriter));
    }

    function _fundImd(address who, uint256 amount) internal override {
        MockERC20(imd).mint(who, amount);
    }
}

/// Every suite in the offline environment.
contract DevTest is Suite, DevEnv {}

/// The stateful suite in the offline environment.
contract DevStatefulTest is Stateful, DevEnv {
    function setUp() public override {
        super.setUp();
        _statefulSetup();
    }
}

/// The ringer alone, against stand-ins whose every chore can misbehave.
contract DevRingerUnitTest is RingerUnit {}

/// The ringer against hostile chores over many days.
contract DevRingerStatefulTest is RingerStateful {}

/// The audit's fixes beyond the audit's reproduction tests (test/repro), and a few figures (dense pools).
contract DevAuditFixesTest is AuditFixes, DevEnv {}

/// The fee root's constant and the residual cap's constants.
contract DevFeeRootAndCapTest is FeeRootAndCap, DevEnv {}

/// The residual's bucket cap and the gas floor's worst case (dense pools).
contract DevResidualCapTest is ResidualCap, DevEnv {
    function setUp() public override(Base, ResidualCap) {
        super.setUp();
    }
}
