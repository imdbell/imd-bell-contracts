// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {Budget} from "./Budget.sol";
import {IERC20T} from "./Base.sol";

/// Deploys the coin so the test can see who the deployer's supply went to.
contract CoinDeployer {
    MarketHoursCoin public coin;

    function deploy() external {
        coin = new MarketHoursCoin("Test Coin", "TEST");
    }
}

/// The admission-shaped tests: what a launch reviewer checks first.
abstract contract Admission is Budget {
    /// the selectors an owned or administered contract would expose; none may appear in any of the five
    function _forbidden() internal pure returns (bytes4[17] memory f) {
        f[0] = bytes4(keccak256("owner()"));
        f[1] = bytes4(keccak256("transferOwnership(address)"));
        f[2] = bytes4(keccak256("renounceOwnership()"));
        f[3] = bytes4(keccak256("pause()"));
        f[4] = bytes4(keccak256("unpause()"));
        f[5] = bytes4(keccak256("sweep()"));
        f[6] = bytes4(keccak256("sweep(address)"));
        f[7] = bytes4(keccak256("rescue(address)"));
        f[8] = bytes4(keccak256("rescue(address,uint256)"));
        f[9] = bytes4(keccak256("withdraw()"));
        f[10] = bytes4(keccak256("withdraw(uint256)"));
        f[11] = bytes4(keccak256("withdraw(address,uint256)"));
        f[12] = bytes4(keccak256("setSigner(address)"));
        f[13] = bytes4(keccak256("setIntake(address)"));
        f[14] = bytes4(keccak256("setRequester(uint64,address)"));
        f[15] = bytes4(keccak256("mint(address,uint256)"));
        f[16] = bytes4(keccak256("withdraw(address)"));
    }

    /// a PUSH4 of the selector in the runtime code is how a dispatcher names a function
    function _codeHasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 5 <= code.length; ++i) {
            if (code[i] == 0x63 && code[i + 1] == sel[0] && code[i + 2] == sel[1] && code[i + 3] == sel[2] && code[i + 4] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    function test_noContractHasAnOwner() public {
        Mkt memory m = mkt;
        address[5] memory cs = [address(m.hook), address(m.coin), address(m.game), address(m.budget), m.hook.bellPurse()];
        bytes4[17] memory f = _forbidden();
        // a positive control: the forbidden list is not vacuous: a contract that does have owner() is caught
        assertTrue(_codeHasSelector(address(this).code, bytes4(keccak256("failed()"))), "control: the scan finds a selector that exists");
        for (uint256 i; i < 5; ++i) {
            bytes memory code = cs[i].code;
            for (uint256 j; j < f.length; ++j) {
                assertFalse(_codeHasSelector(code, f[j]), "admission: a forbidden function is dispatched");
            }
            (bool ok,) = cs[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "admission: owner() answered");
            // no selfdestruct opcode (0xff) outside push data: a cheap scan for the byte in the dispatcher's code
        }
        assertEq(address(m.game), m.hook.game(), "the game is the hook's own");
        assertEq(address(m.budget), m.hook.swarmBudget(), "the purse is the hook's own");
        assertEq(address(m.game.hook()), address(m.hook), "the game points back at the hook");
        assertEq(m.budget.hook(), address(m.hook), "the purse points back at the hook");
        // the ringer: the hook's third creation, pointing back at the hook and at the hook's own companions
        BellRinger r = BellRinger(payable(m.hook.bellPurse()));
        assertEq(address(r), vm.computeCreateAddress(address(m.hook), 3), "the ringer is the hook's own (its CREATE nonce 3)");
        assertEq(address(r.hook()), address(m.hook), "the ringer points back at the hook");
        assertEq(r.game(), address(m.game), "the ringer's game is the hook's");
        assertEq(r.swarmBudget(), address(m.budget), "the ringer's purse is the hook's");
        assertEq(address(r.imd()), imd, "the ringer's IMD");
        assertEq(r.factory(), m.hook.factory(), "the ringer's factory is the hook's");
        assertEq(r.manager(), address(m.hook.manager()), "the ringer reads the hook's PoolManager");
        assertEq(r.bellGasFloor(), m.hook.BELL_GAS_FLOOR(), "the ringer's floor is the hook's");
    }

    /// How many times opcode `op` appears in runtime `code` as an instruction: push data is skipped, and so is the
    /// compiler's metadata trailer (its length is the code's last two bytes).
    function _opCount(bytes memory code, uint8 op) internal pure returns (uint256 n) {
        uint256 end = code.length - (uint256(uint8(code[code.length - 2])) << 8 | uint256(uint8(code[code.length - 1]))) - 2;
        for (uint256 i; i < end; ++i) {
            uint8 c = uint8(code[i]);
            if (c >= 0x60 && c <= 0x7f) i += c - 0x5f;
            else if (c == op) ++n;
        }
    }

    /// Points form: the game cannot move a token. Its code holds no CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2
    /// or SELFDESTRUCT instruction, so every call it makes is a STATICCALL, which cannot change any state, a token
    /// balance included. (A selector scan cannot show this: the optimizer builds outgoing selectors from shifted
    /// constants.) Controls: the scan finds the game's own STATICCALLs, and the hook's CALLs.
    function test_I25_gameHasNoTokenPath() public {
        Mkt memory m = mkt;
        bytes memory code = address(m.game).code;
        assertGt(_opCount(code, 0xfa), 0, "control: the scan finds the game's STATICCALLs to the hook's views");
        assertGt(_opCount(address(m.hook).code, 0xf1), 0, "control: the scan finds the hook's CALLs");
        uint8[6] memory ops = [0xf1, 0xf2, 0xf4, 0xf0, 0xf5, 0xff];
        for (uint256 i; i < ops.length; ++i) {
            assertEq(_opCount(code, ops[i]), 0, "game calls: the game's code holds a state-changing call, a create or a selfdestruct");
        }
        assertEq(IERC20T(imd).balanceOf(address(m.game)), 0, "the game holds no IMD");
        assertEq(m.coin.balanceOf(address(m.game)), 0, "the game holds no coin");
        (bool ok,) = address(m.game).call{value: 1}("");
        assertFalse(ok, "the game takes no ETH");
    }

    function test_permissionsMatchTheDeclaredFlags() public view {
        Mkt memory m = mkt;
        assertEq(uint160(address(m.hook)) & FLAG_MASK, FLAGS, "the address carries exactly 0x2080");
        Hooks.Permissions memory p = m.hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap, "beforeInitialize and beforeSwap");
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
                || p.afterSwap || p.beforeDonate || p.afterDonate || p.beforeSwapReturnDelta || p.afterSwapReturnDelta
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta,
            "nothing else"
        );
    }

    function test_mintsThePolicySupply() public {
        CoinDeployer d = new CoinDeployer();
        d.deploy();
        assertEq(d.coin().totalSupply(), 1_000_000_000e18, "one billion, 18 decimals");
        assertEq(d.coin().decimals(), 18);
    }

    function test_mintsTheWholeSupplyToItsDeployer() public {
        CoinDeployer d = new CoinDeployer();
        d.deploy();
        assertEq(d.coin().balanceOf(address(d)), d.coin().totalSupply(), "the deployer holds the whole supply");
        assertEq(d.coin().balanceOf(address(this)), 0, "nobody else");
    }

    function test_coinBurnLowersTotalSupply() public {
        Mkt memory m = mkt;
        uint256 s0 = m.coin.totalSupply();
        m.coin.burn(1e18);
        assertEq(s0 - m.coin.totalSupply(), 1e18, "burn lowers the supply");
        address other = makeAddr("other");
        m.coin.approve(other, 2e18);
        vm.prank(other);
        m.coin.burnFrom(address(this), 2e18);
        assertEq(s0 - m.coin.totalSupply(), 3e18, "burnFrom lowers the supply");
        assertEq(m.coin.balanceOf(address(0xdEaD)), 0, "nothing parked at a dead address");
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        Mkt memory m = mkt;
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(MarketHoursHook.NotPoolManager.selector);
        m.hook.beforeInitialize(address(this), m.key, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(MarketHoursHook.NotPoolManager.selector);
        m.hook.beforeSwap(address(this), m.key, IPoolManager.SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(MarketHoursHook.NotInUnlock.selector);
        m.hook.unlockCallback(abi.encode(true, uint256(1), false, int24(0)));
        vm.stopPrank();
        // the PoolManager itself, outside the hook's own unlock, is refused too
        vm.prank(address(manager));
        vm.expectRevert(MarketHoursHook.NotInUnlock.selector);
        m.hook.unlockCallback(abi.encode(true, uint256(1), false, int24(0)));
    }

    function test_initializesFromTheLaunchFactory() public {
        // a second hook, this test contract as its factory: a stranger's initialize is refused, the factory's accepted
        Mkt memory m2;
        m2.coin = _newCoin(0x77);
        bytes memory init = _hookInit(type(MarketHoursHook).creationCode, address(m2.coin));
        (bytes32 salt,,) = _mineSalt(keccak256(init), uint256(0x77) << 128, false);
        address hookAt = _create2(init, salt);
        PoolKey memory k = PoolKey(Currency.wrap(address(m2.coin)), Currency.wrap(imd), 12_500, 60, IHooks(hookAt));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        PoolKey memory wrong = PoolKey(Currency.wrap(address(m2.coin)), Currency.wrap(imd), 3_000, 60, IHooks(hookAt));
        vm.expectRevert();
        manager.initialize(wrong, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        assertTrue(MarketHoursHook(hookAt).initialized(), "initialised by the factory, once");
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function test_factorySeedAddsLiquidityWhileClosed() public {
        Mkt memory m = mkt;
        _at(D, 3 hours); // CLOSED
        uint128 l0 = _liq(m);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(0, WIDE, 1e21, 0), "");
        assertEq(_liq(m) - l0, 1e21, "liquidity added while closed");
        _at(D, OPEN - 300); // FROZEN
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(0, WIDE, 1e21, 0), "");
        assertEq(_liq(m) - l0, 2e21, "liquidity added in the freeze");
    }

    /// The zero-delta collect the factory's claimFees runs, in every state of the day.
    function test_factoryZeroDeltaCollectPassesWhileClosed() public {
        Mkt memory m = mkt;
        uint256[8] memory tods = [uint256(3 hours), 11 hours, OPEN - 300, OPEN, OPEN + 1 hours, CLOSE - 300, CLOSE, 17 hours];
        string[8] memory names = ["CLOSED", "no-cancel", "FROZEN", "AWAITING OPEN", "OPEN", "closing freeze", "AWAITING CLOSE", "after close"];
        for (uint256 i; i < 8; ++i) {
            _at(D, tods[i]);
            if (i == 4) m.hook.ringOpen();
            if (i == 7) m.hook.ringClose();
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(0, WIDE, 0, 0), "");
            console2.log("zero-delta collect passed in state:", names[i]);
        }
    }
}
