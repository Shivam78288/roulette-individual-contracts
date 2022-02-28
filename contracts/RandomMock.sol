//SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

contract RandomMock{
    uint256 currentRoundId;
    function latestRoundData(uint num) public returns(
        uint256 roundId, 
        uint256 winner, 
        uint256 timestamp
        ) 
    {
        currentRoundId++;
        return (currentRoundId, 62 - num, block.timestamp);
    }

}