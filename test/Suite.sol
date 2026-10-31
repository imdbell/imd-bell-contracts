// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Mirror} from "./Mirror.sol";

/// Every environment-agnostic suite in one inheritance chain; the offline environment (test/Offline.t.sol) inherits it.
abstract contract Suite is Mirror {}
