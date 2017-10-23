const PythianOracle = artifacts.require('PythianOracle.sol')
const PythianOracleFactory = artifacts.require('PythianOracleFactory.sol')

module.exports = deployer => {
  const args = process.argv.slice()
  if (process.env.DEPLOY_FACTORY){
    deployer.deploy(PythianOracleFactory)
    console.log("Factory deployed")
  } else if (args.length < 6) {
    console.error("To deploy a Pythia contract, pass a list of oracles, " + 
	    "list of oracle weights, and required weight threshold")
  } else {
    deployer.deploy(PythianOracle, args[3].split(","), args[4].split(","), args[5])
    console.log("Pythian Oracle deployed")
  }
}
