pragma solidity ^0.4.15;
import "./Factory.sol";
import "./PythianOracle.sol";

contract PythianOracleFactory is Factory {
    function create(address[] _oracles, uint[] _weights, uint _threshold)
        public
        returns (address oracle)
    {
        oracle = new PythianOracle(_oracles, _weights, _threshold);
        register(oracle);
    }
}
