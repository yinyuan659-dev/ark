// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal INonfungibleTokenPositionDescriptor so we can deploy the official
///         NonfungiblePositionManager bytecode without linking the NFTDescriptor library.
contract SimpleDescriptor {
    function tokenURI(address, uint256 tokenId) external pure returns (string memory) {
        return string.concat("arclaunch-lp:", _toString(tokenId));
    }

    function _toString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory b = new bytes(len);
        while (v != 0) {
            b[--len] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }
}
