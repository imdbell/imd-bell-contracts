// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BellGame} from "src/BellGame.sol";

/// The four views BellGame reads from the hook, with settable answers.
contract StubHook {
    struct O {
        address owner;
        uint256 s;
    }

    mapping(uint256 => O) internal orders;
    int24 internal pStar;
    uint256 internal openedAt;

    function setOrder(uint256 id, address owner, uint256 s) external {
        orders[id] = O(owner, s);
    }

    function setOpen(int24 p, uint256 at) external {
        pStar = p;
        openedAt = at;
    }

    function orderInfo(uint256 id) external view returns (address, uint256, bool, int24, uint256) {
        return (orders[id].owner, orders[id].s, true, int24(0), uint256(5e18));
    }

    function ticketPaid(uint256) external pure returns (bool) {
        return true;
    }

    function sessionMean() external view returns (int256, uint256, uint256, bool) {
        return (int256(0), uint256(0), openedAt, false);
    }

    function bells(uint256) external view returns (int24, bool, bool, uint64, uint64, uint64) {
        return (pStar, openedAt != 0, false, uint64(0), uint64(0), uint64(0));
    }
}

/// Audit 3, finding 3: the audit's attached proof (imports adjusted only), plus the grid rule's two edges. reveal
/// accepted a guess off the 60-tick grid, and the floored distance made one sealed guess an exact hit for two buckets.
/// Correct: a reveal whose guess is not a bucket (off the grid, or above 2 x OFFSET) is refused with BadReveal; an
/// on-grid guess is scored as before.
contract AuditThreeFinding3Test is Test {
    uint256 internal constant D = 20_000;
    int256 internal constant OFFSET = 887_280;
    address internal bob = address(0xB0B);

    /// One wallet, one paid ticket, one sealed guess at `guessedTick`; the next open settles at `settledBucket`.
    function _reveal(int256 guessedTick, int24 settledBucket) internal returns (bool accepted, uint32 dist) {
        (accepted, dist,) = _revealRaw(uint256(guessedTick + OFFSET), settledBucket);
    }

    /// The same, from the raw guess word, with the revert data when refused.
    function _revealRaw(uint256 guess, int24 settledBucket) internal returns (bool accepted, uint32 dist, bytes memory e) {
        StubHook hook = new StubHook();
        BellGame game = new BellGame(address(hook), false);
        vm.warp(D * 1 days + 13 hours);
        hook.setOrder(1, bob, 2 * D + 1);
        bytes32 salt = keccak256("salt");
        vm.prank(bob);
        game.commit(1, keccak256(abi.encode(guess, salt, bob, D + 1)));
        uint256 bell = (D + 1) * 1 days + 12 hours;
        hook.setOpen(settledBucket, bell);
        vm.warp(bell + 31 minutes);
        game.settle(D + 1);
        vm.prank(bob);
        (accepted, e) = address(game).call(abi.encodeCall(BellGame.reveal, (1, guess, salt)));
        if (accepted) dist = game.distOf(D + 1, bob);
    }

    function _is(bytes memory e, bytes4 sel) internal pure returns (bool) {
        return e.length >= 4 && bytes4(e) == sel;
    }

    /// A sealed guess names one bucket: the same value may not be an exact hit (distance 0) for two different buckets.
    function test_oneSealedGuessIsNotExactForTwoBuckets() public {
        (bool ok0, uint32 d0) = _reveal(30, 0);
        (bool ok1, uint32 d1) = _reveal(30, 60);
        assertFalse(ok0 && d0 == 0 && ok1 && d1 == 0, "tick 30 scored distance 0 against bucket 0 and against bucket 60");
    }

    /// An off-grid guess is refused at reveal with BadReveal, the existing error; the committer has spent the day's
    /// guess and reveals nothing.
    function test_A3F3_offGridGuessRefusedWithBadReveal() public {
        (bool ok,, bytes memory e) = _revealRaw(uint256(30 + OFFSET), 0);
        assertFalse(ok, "an off-grid guess was accepted");
        assertTrue(_is(e, BellGame.BadReveal.selector), "refused with BadReveal");
    }

    /// A guess above 2 x OFFSET is no bucket either (it would decode past the grid): refused with BadReveal.
    function test_A3F3_guessAboveTheGridRefusedWithBadReveal() public {
        (bool ok,, bytes memory e) = _revealRaw(uint256(2 * OFFSET + 60), 0);
        assertFalse(ok, "a guess above 2 x OFFSET was accepted");
        assertTrue(_is(e, BellGame.BadReveal.selector), "refused with BadReveal");
    }

    /// CONTROL: on-grid guesses score as before: an exact hit at distance 0, one bucket off at distance 1, and the
    /// grid's top word (2 x OFFSET) is accepted.
    function test_A3F3_control_onGridGuessesScore() public {
        (bool ok0, uint32 d0) = _reveal(0, 0);
        assertTrue(ok0 && d0 == 0, "an exact on-grid hit scores distance 0");
        (bool ok1, uint32 d1) = _reveal(60, 0);
        assertTrue(ok1 && d1 == 1, "one bucket off scores distance 1");
        (bool ok2,,) = _revealRaw(uint256(2 * OFFSET), 0);
        assertTrue(ok2, "the grid's top word is a bucket");
    }
}
