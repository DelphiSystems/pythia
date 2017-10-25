pragma solidity ^0.4.15;

contract Factory {
    mapping(address => bool) public isInstantiation;
    mapping(address => address[]) public instantiations;

    event ContractInstantiation(address sender, address instantiation);

    function getInstantiationCount(address creator)
        public
        constant
        returns (uint)
    {
        return instantiations[creator].length;
    }

    function register(address instantiation)
        internal
    {
        isInstantiation[instantiation] = true;
        instantiations[msg.sender].push(instantiation);
        ContractInstantiation(msg.sender, instantiation);
    }
}
