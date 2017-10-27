pragma solidity ^0.4.15;

/*************************************************************************\
 *   Pythia: Weighted multisignature oracle contract
 *
 *   Oracle account controlled via weighted multisignature transaction
 *   proposals. Each oracle is assigned a weight value, and proposed
 *   transactions are only authorized and executable once they have
 *   reached a certain weight threshold.
 *
 *   Standard Pythian Oracle: after oracles and weights are initially
 *   established, they can be updated if a sufficient oracle weight
 *   invokes the update (i.e. if the contract successfully calls itself)
 *
\*************************************************************************/
contract PythianOracle {
    /*************\
     *  Storage  *
    \*************/
    uint constant public MAX_ORACLES = 31;                              // Upper bound on loop length

    mapping (uint => Transaction) public transactions;                  // Transactions (proposed and executed)
    mapping (uint => mapping (address => bool)) public supporters;      // Map of supporters of each txid
    mapping (address => bool) public isOracle;                          // Map to ensure oracle uniqueness
    address[] public oracles;                                           // List of oracles
    uint[] public weights;                                              // List of oracle weights
    uint public threshold;                                              // Weight threshold to confirm transactions
    uint public txCount;                                                // Total count of transactions

    /************\
     *  Events  *
    \************/
    event Proposal(uint indexed txid);                                  // Transaction is proposed
    event Support(address indexed sender, uint indexed txid);           // Oracle supports transaction
    event Revocation(address indexed sender, uint indexed txid);        // Oracle revokes transaction support
    event Execution(uint indexed txid);                                 // Transaction successfully executed
    event ExecutionFailure(uint indexed txid);                          // Transaction execution failed
    event Deposit(address indexed sender, uint value);                  // Deposit is made into contract
    event OracleAddition(address indexed oracle);                       // Oracle is added to the contract
    event OracleRemoval(address indexed oracle);                        // Oracle is removed from contract
    event ThresholdChange(uint _threshold);                             // Threshold is updated

    /*************\
     *  Structs  *
     **************************************************************\
     *  Transaction (proposal)
     *  @dev Represents a transaction call (master oracle output)
     *       Tracks transactional information and whether it has
     *       been successfully executed by the Pythia.
    \**************************************************************/
    struct Transaction {
        address destination;
        uint value;
        bytes data;
        bool executed;
    }

    /**************\
     *  Modifiers
    \**************/
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

    /*********************\
     *  Public functions
     ************************************************************\
     *  @dev Constructor
     *  @param _oracles Addresses of constituent oracles
     *  @param _weights Weights of constituent oracles
     *  @param _threshold Weight threshold that must be reached
     *                    in order to execute a transaction
    \************************************************************/
    function PythianOracle(address[] _oracles, uint[] _weights, uint _threshold)
        public
    {
        assert(_oracles.length > 0);
        assert(_oracles.length <= MAX_ORACLES);
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

    /******************************\
     *  @dev Deposit function
     *  Anyone can pay the oracle
    \******************************/
    function()
        public
        payable
    {
        // Only accept nonzero deposits
        if (msg.value > 0) {
            // Fire Deposit event
            Deposit(msg.sender, msg.value);
        }
    }

    /**************************************************************\
     *  @dev Propose transaction function; begin the generation
     *       of a transaction output
     *  @param destination Recipient address
     *  @param value Transaction value (ETH sent with it)
     *  @param data Transaction data (used for calling functions)
     *  @return TransactionID (oracle transaction identifier)
    \**************************************************************/
    function proposeTransaction(address destination, uint value, bytes data)
        public
        returns (uint txid)
    {
        txid = addTransaction(destination, value, data);
        supportTransaction(txid);
    }

    /**************************************************************\
     *  @dev Support transaction function; assign personal oracle
     *       weight behind a proposed transaction
     *  @param txid Transaction proposal being supported
    \**************************************************************/
    function supportTransaction(uint txid)
        public
        oracleExists(msg.sender)
        transactionExists(txid)
        notSupported(txid, msg.sender)
    {
        // Log support
        supporters[txid][msg.sender] = true;
        // Fire Support event
        Support(msg.sender, txid);
        // Attempt to execute, just in case threshold was passed
        executeTransaction(txid);
    }

    /***************************************************************\
     *  @dev Revoke support function; de-assign personal oracle
     *       weight from a proposed transaction
     *  @param txid Transaction proposal no longer being supported
    \***************************************************************/
    function revokeSupport(uint txid)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        // Log the removal of support
        supporters[txid][msg.sender] = false;
        // Fire Revocation event
        Revocation(msg.sender, txid);
    }

    /***************************************************************\
     *  @dev Execute transaction function; actually perform a
     *       transaction after the support weight threshold has
     *       been reached.
     *  @param txid Transaction being executed
    \***************************************************************/
    function executeTransaction(uint txid)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        // Transactions can only be executed once confirmed (weight threshold reached)
        if (isConfirmed(txid)) {
            Transaction storage executedTransaction = transactions[txid];
            // Mark as executed before call attempt is made (avoids reentrancy problems)
            executedTransaction.executed = true;
            // Attempt the transaction call
            if (executedTransaction.destination.call.value(executedTransaction.value)(executedTransaction.data)) {
                // Fire ExecutionFailure event
                Execution(txid);
            } else {
                // Fire ExecutionFailure event
                ExecutionFailure(txid);
                // Mark transaction as un-executed (call failed)
                executedTransaction.executed = false;
            }
        }
    }

    /***************************************************************\
     *  @dev Execute transaction function; actually perform a
     *       transaction after the support weight threshold has
     *       been reached. Allows gas specification.
     *  @param txid Transaction being executed
     *  @param specificGas Gas value allocated for execution
    \***************************************************************/
    function executeTransaction(uint txid, uint specificGas)
        public
        oracleExists(msg.sender)
        supported(txid, msg.sender)
        notExecuted(txid)
    {
        // Transactions can only be executed once confirmed (weight threshold reached)
        if (isConfirmed(txid)) {
            Transaction storage executedTransaction = transactions[txid];
            // Mark as executed before call attempt is made (avoids reentrancy problems)
            executedTransaction.executed = true;
            // Attempt the transaction call (pass specificGas value)
            if (executedTransaction.destination.call.value(executedTransaction.value).gas(specificGas)(executedTransaction.data)) {
                // Fire ExecutionFailure event
                Execution(txid);
            } else {
                // Fire ExecutionFailure event
                ExecutionFailure(txid);
                // Mark transaction as un-executed (call failed)
                executedTransaction.executed = false;
            }
        }
    }

    /***************************************************************\
     *  @dev Check a transaction to see if the support weight
     *       threshold has been reached.
     *  @param txid Transaction being checked
     *  @return Whether the weight threshold has been reached
    \***************************************************************/
    function isConfirmed(uint txid)
        public
        constant
        returns (bool)
    {
        uint totalWeight = 0;
        for (uint i=0; i<oracles.length; i++) {
            // Accumulate weight if oracle supports transaction
            if (supporters[txid][oracles[i]]) {
                totalWeight += weights[i];
            }
            // If the cumulative support weight ever passes weight threshold
            if (totalWeight >= threshold) {
                return true;
            }
        }
    }

    /***************************************************************\
     *  @dev Add a transaction proposal to oracle storage
     *  @param destination Recipient address
     *  @param value Transaction value (ETH sent with it)
     *  @param data Transaction data (used for calling functions)
     *  @return txid (oracle transaction identifier)
    \**************************************************************/
    function addTransaction(address destination, uint value, bytes data)
        internal
        notNull(destination)
        returns (uint txid)
    {
        txid = txCount;
        // Append to transaction list
        transactions[txid] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });
        // Update transaction count index
        txCount += 1;
        // Fire Proposal event
        Proposal(txid);
    }

    /******************************\
     *  Dynamic oracle functions  *
     *****************************************************\
     *  @dev Add oracle to contract
     *  @param oracle Address of newly added oracle
     *  @param weight New oracle's weight value
     *  @param newThreshold New total weight threshold
     *                      (probably should be updated)
    \*****************************************************/
    function addOracle(address oracle, uint weight, uint newThreshold)
        public
        onlyPythia
        noSuchOracle(oracle)
        notNull(oracle)
    {
        assert(oracles.length < MAX_ORACLES);
        isOracle[oracle] = true;
        oracles.push(oracle);
        weights.push(weight);
        checkThreshold(newThreshold);
        assert(oracles.length == weights.length);

        OracleAddition(oracle);
    }

    /*****************************************************\
     *  @dev Remove oracle from contract
     *  @param oracle Address of (now former) oracle
     *  Will drop threshold by oracle's weight value
    \*****************************************************/
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
        // Sanity checks
        assert(oracles.length == weights.length);
        assert(oracles.length > 0);

        // Fire OracleRemoval event
        OracleRemoval(oracle);
    }

    /*****************************************************\
     *  @dev Replace oracle in contract (weight remains)
     *  @param oracle Address of (now former) oracle
     *  @param newOracle Address of oracle replacing it
    \*****************************************************/
    function replaceOracle(address oracle, address newOracle)
        public
        onlyPythia
        oracleExists(oracle)
        noSuchOracle(newOracle)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (oracles[i] == oracle) {
                // Replace old oracle with new one
                oracles[i] = newOracle;
                break;
            }
        }
        // Update oracle trackers
        isOracle[oracle] = false;
        isOracle[newOracle] = true;
        // Sanity check
        assert(oracles.length == weights.length);
        // Fire OracleRemoval event
        OracleRemoval(oracle);
        // Fire OracleAddition event
        OracleAddition(newOracle);
    }

    /******************************************\
     *  @dev Change required weight threshold
     *  @param _threshold New threshold value
     *  Must pass a checkThreshold() check
    \******************************************/
    function changeThreshold(uint _threshold)
        public
        onlyPythia
    {
        // Check to ensure new threshold is a sane value
        checkThreshold(_threshold);
        // Set new weight threshold
        threshold = _threshold;
        // Fire ThresholdChange event
        ThresholdChange(_threshold);
    }

    /************************\
     *  Accessor functions  *
     ********************************************\
     *  @dev Get weight value of a given oracle
     *  @param oracle The relevant oracle
     *  @return weight Oracle's weight value
    \********************************************/
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
        // If oracle was not found, its weight value is zero
        return 0;
    }

    /***************************************************************************\
     *  @dev Get count (not weight) of oracles who support a given transaction
     *  @param txid Transaction being analyzed
     *  @return count Total count of supporting oracles (without weights)
    \***************************************************************************/
    function getSupporterCount(uint txid)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<oracles.length; i++) {
            if (supporters[txid][oracles[i]]) {
                count += 1;
            }
        }
    }

    /*****************************************************************\
     *  @dev Get the weighted oracle support for a given transaction
     *  @param txid Transaction being analyzed
     *  @return weight Total oracle support weight transaction has
    \*****************************************************************/
    function getSupportWeight(uint txid)
        public
        constant
        returns (uint weight)
    {
        for (uint i=0; i<oracles.length; i++) {
            // If this oracle supports this transaction proposal...
            if (supporters[txid][oracles[i]]) {
                // Add oracle weight to total support weight
                weight += weights[i];
            }
        }
    }

    /*******************************************************************\
     *  @dev Get count of transactions which satisfy given criteria
     *  @param pending Qualifier to include pending transactions
     *  @param executed Qualifier to include executed transactions
     *  @return count Total transactions satisfying specified criteria
    \*******************************************************************/
    function getTxCount(bool pending, bool executed)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<txCount; i++) {
            // Check against criteria
            if (pending && !transactions[i].executed || executed && transactions[i].executed) {
                count += 1;
            }
        }
    }

    /************************************************************\
     *  @dev Get list of oracles involved with this contract
     *  @return Oracle list (without weights)
    \************************************************************/
    function getOracles()
        public
        constant
        returns (address[])
    {
        return oracles;
    }

    /*****************************************************\
     *  @dev Get list of oracle weights of this contract
     *  @return Oracle list (without weights)
    \*****************************************************/
    function getWeights()
        public
        constant
        returns (uint[])
    {
        return weights;
    }

    /*********************************************************************\
     *  @dev Get list of oracles who support a given transaction
     *  @param txid Transaction being analyzed
     *  @return _supporters List of supporting oracles (without weights)
    \*********************************************************************/
    function getOraclesWhoSupport(uint txid)
        public
        constant
        returns (address[] _supporters)
    {
        // Because we do not know how long our final result array will be,
        // we use a temporary variable here.
        address[] memory supportersTemp = new address[](oracles.length);
        uint count = 0;
        uint i;
        for (i=0; i<oracles.length; i++) {
            // If oracle supports this transaction
            if (supporters[txid][oracles[i]]) {
                supportersTemp[count] = oracles[i];
                count += 1;
            }
        }
        // Now we know how long our result is, so we allocate a proper-sized
        // array to return it.
        _supporters = new address[](count);
        for (i=0; i<count; i++) {
            _supporters[i] = supportersTemp[i];
        }
    }

    /**************************************************************************\
     *  @dev Get list of transactions in a range which satisfy given criteria
     *  @param from Transaction index beginning
     *  @param to Transaction index end
     *  @param pending Qualifier to include pending transactions
     *  @param executed Qualifier to include executed transactions
     *  @return count Total transactions satisfying specified criteria
    \**************************************************************************/
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

    /***********************\
     *  Private functions  *
     *************************************************************\
     *  @dev sum function (helper function for threshold checks)
     *  Returns the sum of the elements of an array of uints.
    \*************************************************************/
    function sum(uint[] self) private returns (uint s) {
        for (uint i = 0; i < self.length; i++) {
            s += self[i];
        }
    }

    /****************************************************\
     *  @dev Ensure that a new weight threshold is sane
    \****************************************************/
    function checkThreshold(uint _threshold) private {
        if (_threshold > sum(weights) || _threshold == 0 || sum(weights) == 0) {
            revert();
        }
    }
}
