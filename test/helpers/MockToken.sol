// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token code etched at the two fixed production token addresses.
contract MockToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        ShortTransfer,
        NoTransfer,
        NoReturn,
        RevertTransfer,
        ExtraTransfer
    }

    Mode public pullMode;
    Mode public pushMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnPull;
    bool public callbackOnPush;
    bool public callbackSuccess;
    bytes public callbackResult;

    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setModes(Mode pull, Mode push) external {
        pullMode = pull;
        pushMode = push;
    }

    function setCallback(address target, bytes calldata data, bool onPull, bool onPush) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnPull = onPull;
        callbackOnPush = onPush;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (pushMode == Mode.ReturnFalse) return false;
        require(pushMode != Mode.RevertTransfer, "mock push failure");
        if (pushMode != Mode.NoTransfer) {
            _transfer(msg.sender, to, pushMode == Mode.ShortTransfer ? amount - 1 : amount);
        }
        if (callbackOnPush) _callback();
        if (pushMode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (pullMode == Mode.ReturnFalse) return false;
        require(pullMode != Mode.RevertTransfer, "mock pull failure");
        _spendAllowance(from, msg.sender, amount);
        if (pullMode != Mode.NoTransfer) {
            _transfer(from, to, pullMode == Mode.ShortTransfer ? amount - 1 : amount);
        }
        if (pullMode == Mode.ExtraTransfer) _mint(to, 1);
        if (callbackOnPull) _callback();
        if (pullMode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _callback() private {
        (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
    }
}
