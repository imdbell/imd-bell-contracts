// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {SeedFigures} from "./SeedFigures.s.sol";
import {LaunchShape} from "./LaunchShape.sol";

interface IFactoryD {
    function poolManager() external view returns (address);
    function fees() external view returns (address);
    function deployer() external view returns (address);
    function predictToken(uint64 launchNumber, bytes calldata tokenCreationCode) external view returns (address);
    function predictHook(bytes calldata hookCreationCode, bytes32 hookSalt) external view returns (address);
}

interface IExecutorD {
    function token() external view returns (address);
}

interface IERC20D {
    function symbol() external view returns (string memory);
}

/// Assembles what a launch needs and prints it. It never broadcasts: the launch itself is made by the factory's deployer
/// from a request, with the creation code this prints. Every address but the factory and the burn executor is read from
/// chain. The pool's currency order follows from the predicted coin against IMD: the planned range and its start
/// at the lower edge are kept for a coin that is currency0 and mirrored for one that is currency1 (script/LaunchShape.sol),
/// so the seed is coin-only and the start price in IMD per coin is the same either way.
contract Deploy is Script {
    address internal constant FACTORY = 0x12C63b581d07093F6126bc02263c58f7EadaA96F;
    address internal constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    uint160 internal constant FLAGS = 0x2080;

    function run() external {
        IFactoryD f = IFactoryD(FACTORY);
        address manager = f.poolManager();
        address fees = f.fees();
        address imd = IExecutorD(BURN_EXECUTOR).token();
        require(keccak256(bytes(IERC20D(imd).symbol())) == keccak256("IMD"), "the executor's token is not IMD");
        address intake = vm.envAddress("INTAKE");
        uint64 launchNumber = uint64(vm.envUint("LAUNCH_NUMBER"));
        string memory name = vm.envString("COIN_NAME");
        string memory symbol = vm.envString("COIN_SYMBOL");
        uint128 seedL = uint128(vm.envUint("SEED_LIQUIDITY"));
        // the planned range, written for a coin that is currency0; its start is the lower edge
        int24 modelTl = int24(vm.envInt("MODEL_TL"));
        int24 modelTu = int24(vm.envInt("MODEL_TU"));
        address feeWallet = vm.envAddress("FEE_WALLET");

        bytes memory tokenCode = abi.encodePacked(type(MarketHoursCoin).creationCode, abi.encode(name, symbol));
        address token = f.predictToken(launchNumber, tokenCode);
        LaunchShape.Shape memory sh = LaunchShape.shapeOf(token, imd, modelTl, modelTu);
        (uint256 seedCoin, uint256 seedImd) = LaunchShape.seed(sh, seedL);
        require(seedImd == 0, "the seed is not coin-only");
        SeedFigures fig = new SeedFigures();
        (int24 ticksX, uint256 maxSwapImd) = fig.figuresFor(seedL, sh.startBucket, 12_500, sh.coinIs0);

        MarketHoursHook.Params memory p;
        p.manager = IPoolManager(manager);
        p.factory = FACTORY;
        p.imd = imd;
        p.coin = token;
        p.feeWallet = feeWallet;
        p.burnExecutor = BURN_EXECUTOR;
        p.launchFees = fees;
        p.intake = intake;
        p.maxBlockMoveBps = 500;
        p.maxSwapImd = maxSwapImd;
        p.networkBps = 2000;
        p.feeWalletBps = 2000;
        p.swarmFeeBps = 1000;
        p.burnBps = 4000;
        p.bellPurseBps = 1000;
        p.launchNumber = launchNumber;
        bytes memory hookCode = abi.encodePacked(type(MarketHoursHook).creationCode, abi.encode(p));
        require(hookCode.length <= 49_152, "hook creation code over the EIP-3860 limit");
        bytes32 h = keccak256(hookCode);
        bytes32 salt;
        address hookAt;
        for (uint256 i;; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, bytes32(i), h)))));
            if (uint160(a) & 0x3FFF == FLAGS) {
                salt = bytes32(i);
                hookAt = a;
                break;
            }
        }
        require(f.predictHook(hookCode, salt) == hookAt, "prediction differs from the factory's");

        console2.log("== constructor arguments (read from chain unless stated) ==");
        console2.log("factory (given)", FACTORY);
        console2.log("factory.deployer()", f.deployer());
        console2.log("PoolManager = factory.poolManager()", manager);
        console2.log("LaunchFees = factory.fees()", fees);
        console2.log("BurnExecutor (given, verified by token())", BURN_EXECUTOR);
        console2.log("IMD = BurnExecutor.token()", imd);
        console2.log("Intake (from Medici's treasury bytecode)", intake);
        console2.log("FEE_WALLET (env)", feeWallet);
        console2.log("coin (predicted for the launch number)", token);
        console2.log("coin sorts below IMD (coin is currency0)", sh.coinIs0);
        console2.log("pool currency0", sh.coinIs0 ? token : imd);
        console2.log("pool currency1", sh.coinIs0 ? imd : token);
        console2.log("model range tickLower", int256(modelTl));
        console2.log("model range tickUpper", int256(modelTu));
        console2.log("pool range tickLower", int256(sh.tickLower));
        console2.log("pool range tickUpper", int256(sh.tickUpper));
        console2.log("start tick", int256(sh.startTick));
        console2.log("start sqrtPriceX96", uint256(sh.sqrtPriceX96));
        console2.log("start bucket (IMD per coin)", int256(sh.startBucket));
        console2.log("seed coin (wei)", seedCoin);
        console2.log("seed IMD (wei)", seedImd);
        console2.log("X bps", uint256(500));
        console2.log("ticks(X)", int256(ticksX));
        console2.log("MAX_SWAP_IMD (wei)", maxSwapImd);
        console2.log("shares: network / fee wallet / swarm / burn bps", uint256(2000), uint256(2000), uint256(1000));
        console2.log("burn bps", uint256(4000));
        console2.log("bell purse bps", uint256(1000));
        console2.log("launch number (the ringer's claimFees chore)", uint256(launchNumber));
        console2.log("hook salt", uint256(salt));
        console2.log("hook (predicted)", hookAt);
        // the hook's constructor creates the purse, the game, then the ringer: its CREATE nonces 1, 2 and 3 (a contract
        // starts at nonce 1)
        console2.log("purse (predicted, the hook's CREATE nonce 1)", vm.computeCreateAddress(hookAt, 1));
        console2.log("game (predicted, the hook's CREATE nonce 2)", vm.computeCreateAddress(hookAt, 2));
        console2.log("ringer (predicted, the hook's CREATE nonce 3)", vm.computeCreateAddress(hookAt, 3));
        console2.log("hook creation bytes incl. args", hookCode.length);
        console2.log("token creation bytes incl. args", tokenCode.length);
    }
}

