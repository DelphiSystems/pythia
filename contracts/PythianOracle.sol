pragma solidity ^0.4.15;

contract PythianOracle {
    uint constant public MAX_ORACLE_COUNT = 50;

    mapping (uint => Transaction) public transactions;
    mapping (uint => mapping (address => bool)) public supporters;
    mapping (address => bool) public isOracle;
    address[] public oracles;
    uint[] public weights;
    uint public threshold;
    uint public txCount;

    event Proposal(uint indexed txid);
    event Support(address indexed sender, uint indexed txid);
    event Revocation(address indexed sender, uint indexed txid);
    event Execution(uint indexed txid);
    event ExecutionFailure(uint indexed txid);
    event Deposit(address indexed sender, uint value);
    event OracleAddition(address indexed oracle);
    event OracleRemoval(address indexed oracle);
    event ThresholdChange(uint _threshold);

    struct Transaction {
        address destination;
        uint value;
        bytes data;
        bool executed;
    }

    modifier onlyPythia() {
        if (msg.sender != address(this))
            revert();
        _;
    }

    modifier noSuchOracle(address oracle) {
        if (isOracle[oracle])
            revert();
        _;
    }

    modifier oracleExists(address oracle) {
        if (!isOracle[oracle])
            revert();
        _;
    }

    modifier transactionExists(uint txid) {
        if (transactions[txid].destination == 0)
            revert();
        _;
    }

    modifier supported(uint txid, address oracle) {
        if (!supporters[txid][oracle])
            revert();
        _;
    }

    modifier notSupported(uint txid, address oracle) {
        if (supporters[txid][oracle])
            revert();
        _;
    }

    modifier notExecuted(uint txid) {
        if (transactions[txid].executed)
            revert();
        _;
    }

    modifier notNull(address _address) {
        if (_address == 0)
            revert();
        _;
    }

    function sum(uint[] self) private returns (uint s) {
        for (uint i = 0; i < self.length; i++) {
            s += self[i];
        }
    }

    function()
        public
        payable
    {
        if (msg.value > 0)
            Deposit(msg.sender, msg.value);
    }

    function PythianOracle(address[] _oracles, uint[] _weights, uint _threshold)
        public
    {
        assert(_oracles.length == _weights.length);
        for (uint i=0; i<_oracles.length; i++) {
            if (isOracle[_oracles[i]] || _oracles[i] == 0)
                revert();
            isOracle[_oracles[i]] = true;
        }
        oracles = _oracles;
        weights = _weights;
        threshold = _threshold;
        checkThreshold(_threshold);
    }

    function addOracle(address oracle, uint weight, uint newThreshold)
        public
        onlyPythia
        noSuchOracle(oracle)
        notNull(oracle)
    {
        isOracle[oracle] = true;
        oracles.push(oracle);
        weights.push(weight);
        checkThreshold(newThreshold);
        assert(oracles.length == weights.length);

        OracleAddition(oracle);
    }

    function checkThreshold(uint _threshold) private {
        if (_threshold > sum(weights) || _threshold == 0 || sum(weights) == 0) {
            revert();
        }
    }

    function removeOracle(address oracle)
        public
        onlyPythia
        oracleExists(oracle)
    {
        uint removedWeight = 0;
        uint currentWeightSum = sum(weights);
        isOracle[oracle] = false;
        for (uint i=0; i<oracles.length - 1; i++) {
            if (oracles[i] == oracle) {
                removedWeight = weights[i];
                oracles[i] = oracles[oracles.length - 1];
                weights[i] = weights[weights.length - 1];
                break;
            }
        }
        oracles.length -= 1;
        weights.length -= 1;
        if (currentWeightSum - removedWeight > threshold) {
            changeThreshold(currentWeightSum - removedWeight);
        }
        assert(oracles.length == weights.length);

        OracleRemoval(oracle);
    }

    function replaceOracle(address oracle, address newOracle)
        public
        onlyPythia
        oracleExists(oracle)
        noSuchOracle(newOracle)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (oracles[i] == oracle) {
                oracles[i] = newOracle;
                break;
            }
        }
        isOracle[oracle] = false;
        isOracle[newOracle] = true;
        assert(oracles.length == weights.length);
        OracleRemoval(oracle);
        OracleAddition(newOracle);
    }

    function changeThreshold(uint _threshold) 
        public
        onlyPythia
    {
        checkThreshold(_threshold);
        threshold = _threshold;
        ThresholdChange(_threshold);
    }

    function proposeTransaction(address destination, uint value, bytes data)
        public
        returns (uint txid)
    {
        txid = addTransaction(destination, value, data);
        supportTransaction(txid);
    }

    function supportTransaction(uint txid)
        public
        oracleExists(msg.sender)
        transactionExists(txid)
        notSupported(txid, msg.sender)
    {
        supporters[txid][msg.sender] = true;
        Support(msg.sender, txid);
        executeTransaction(txid);
    }

    function revokeSupport(uint txid)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        supporters[txid][msg.sender] = false;
        Revocation(msg.sender, txid);
    }

    function executeTransaction(uint txid)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        if (isConfirmed(txid)) {
            Transaction storage executedTransaction = transactions[txid];
            executedTransaction.executed = true;
            if (executedTransaction.destination.call.value(executedTransaction.value)(executedTransaction.data)) {
                Execution(txid);
            } else {
                ExecutionFailure(txid);
                executedTransaction.executed = false;
            }
        }
    }

    function executeTransaction(uint txid, uint specificGas)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        if (isConfirmed(txid)) {
            Transaction storage executedTransaction = transactions[txid];
            executedTransaction.executed = true;
            if (executedTransaction.destination.call.value(executedTransaction.value).gas(specificGas)(executedTransaction.data)) {
                Execution(txid);
            } else {
                ExecutionFailure(txid);
                executedTransaction.executed = false;
            }
        }
    }

    function isConfirmed(uint txid)
        public
        constant
        returns (bool)
    {
        uint totalWeight = 0;
        for (uint i=0; i<oracles.length; i++) {
            if (supporters[txid][oracles[i]])
                totalWeight += weights[i];
            if (totalWeight >= threshold)
                return true;
        }
    }

    function addTransaction(address destination, uint value, bytes data)
        internal
        notNull(destination)
        returns (uint txid)
    {
        txid = txCount;
        transactions[txid] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });
        txCount += 1;
        Proposal(txid);
    }

    function getOracleWeight(address oracle)
        public
        constant
        returns (uint weight)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (oracles[i] == oracle) {
                return weights[i];
            }
        }
        return 0;
    }

    function getSupporterCount(uint txid)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (supporters[txid][oracles[i]])
                count += 1;
        }
    }

    function getSupportWeight(uint txid)
        public
        constant
        returns (uint weight)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (supporters[txid][oracles[i]])
                weight += weights[i];
        }
    }

    function getTxCount(bool pending, bool executed)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<txCount; i++) {
            if (pending && !transactions[i].executed || executed && transactions[i].executed)
                count += 1;
        }
    }

    function getOracles()
        public
        constant
        returns (address[])
    {
        return oracles;
    }

    function getWeights()
        public
        constant
        returns (uint[])
    {
        return weights;
    }

    function getOraclesWhoSupport(uint txid)
        public
        constant
        returns (address[] _supporters)
    {
        address[] memory supportersTemp = new address[](oracles.length);
        uint count = 0;
        uint i;
        for (i=0; i<oracles.length; i++) {
            if (supporters[txid][oracles[i]]) {
                supportersTemp[count] = oracles[i];
                count += 1;
            }
        }
        _supporters = new address[](count);
        for (i=0; i<count; i++) {
            _supporters[i] = supportersTemp[i];
        }
    }

    function getTransactionIDs(uint from, uint to, bool pending, bool executed)
        public
        constant
        returns (uint[] _txids)
    {
        uint[] memory txidsTemp = new uint[](txCount);
        uint count = 0;
        uint i;
        for (i=0; i<txCount; i++) {
            if (pending && !transactions[i].executed || executed && transactions[i].executed) {
                txidsTemp[count] = i;
                count += 1;
            }
        }
        _txids = new uint[](to - from);
        for (i=from; i<to; i++) {
            _txids[i - from] = txidsTemp[i];
        }
    }
}
