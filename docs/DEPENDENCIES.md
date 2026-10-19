# Vendored dependencies

Dependencies are unmodified upstream Solidity sources and license files, stored as ordinary repository files. No submodules, package-manager installation, FFI, or filesystem permissions are required. Unused OpenZeppelin sources are omitted; forge-std's source tree is retained to support independent tests.

| Package | Release | Upstream archive | Archive SHA-256 |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2 | `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a` |
| forge-std | v1.9.7 | https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7 | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

OpenZeppelin provides `SafeERC20`, `EIP712`, `ECDSA`, `Math`, `Pausable`, `ReentrancyGuard` and their transitive dependencies. Its ERC-20 implementation is used only by local test mocks. Library functions used by BetPool are internal and inline into the application; there are no deployed library links.

OpenZeppelin's MIT license is in `lib/openzeppelin-contracts/LICENSE`. forge-std's MIT and Apache-2.0 licenses are in `lib/forge-std/LICENSE-MIT` and `lib/forge-std/LICENSE-APACHE`.
