// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
library QuorumCreate {
    function deploy(address source,bytes memory args) internal returns(address result){
        uint256 length=source.code.length;require(length>1,"creation data");
        bytes memory init=new bytes(length-1+args.length);
        assembly("memory-safe"){
            extcodecopy(source,add(init,32),1,sub(length,1))
            mcopy(add(add(init,32),sub(length,1)),add(args,32),mload(args))
            result:=create(0,add(init,32),mload(init))
        }
        require(result!=address(0),"immutable component deployment");
    }
}
