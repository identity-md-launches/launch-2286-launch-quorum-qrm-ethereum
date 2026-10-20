// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Immutable onchain text storage prototype. No governance or deployment integration.
contract ConstitutionTextPrototype {
    constructor(bytes memory text_) {
        require(text_.length > 0 && text_.length <= 24575, "text size");
        bytes memory runtime = bytes.concat(hex"00", text_);
        assembly { return(add(runtime, 32), mload(runtime)) }
    }
}
contract ConstitutionPrototype {
    address public immutable textAddress;
    bytes32 public immutable constitutionHash;
    uint256 public immutable textLength;
    constructor(bytes memory approvedText) {
        constitutionHash = sha256(approvedText);
        textLength = approvedText.length;
        textAddress = address(new ConstitutionTextPrototype(approvedText));
    }
    function text() external view returns (bytes memory result) {
        result = new bytes(textLength);
        address source = textAddress;
        uint256 length = textLength;
        assembly { extcodecopy(source, add(result, 32), 1, length) }
    }
}

