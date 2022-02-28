require('dotenv').config();
const Roulette = artifacts.require('Roulette');
const { deployProxy } = require('@openzeppelin/truffle-upgrades');

const owner = process.env.OPERATOR;
const admin = process.env.OPERATOR;
const operator=process.env.OPERATOR;
const ownerAdminOperator = [owner, admin, operator];

const paramsMumbai = web3.eth.abi.encodeParameters(
    ["address", "uint8", "uint256", "address"],
    [
        "0xce746F6E5E99d9EE3457d1dcE5F69F4E27c12BD4", 
        18, 
        15, 
        "0xe5e59A851406A2B61B4C3142c89F3E12623340E1"
    ],
  );

// const paramsMainnet = web3Mainnet.eth.abi.encodeParameters(
//     ["address", "uint8", "uint256[]", "uint256", "uint256", "address"],
//     [tokenStakedMatic, decimalsMatic, lockCloseInterval, buffer, oracleUpdateAllowance, randomGeneratorMatic],
// );

module.exports = async function (deployer, network) {

    if (network === 'mumbai'){
        await deployProxy(Roulette, [paramsMumbai, ownerAdminOperator], 
            { deployer, initializer: 'initialize', kind: 'uups' });
    }
    
    // else{
    //     await deployProxy(Roulette, [paramsMainnet, ownerAdminOperator], 
    //         { deployer, initializer: 'initialize', kind: 'uups' });
    // }   

};
