// SPDX-License-Identifier: MIT

pragma solidity ^0.8.5;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IRandomGenerator.sol";

contract Roulette is 
    Initializable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Round {
        uint256 roundId;
        uint256 epoch;
        Bet[] bets;
        uint256 totalAmountBet;
        uint256 totalRewardAmount;
        uint256 treasuryCollections;
        bool oracleCalled;
        uint8 winningNumber;
        bool claimed;
        // the amount put on a number with a slab
        // totalAmountInSlabs[number][slab] = total amount bet on that number in a slab
        mapping(uint8 => mapping(uint8 => uint256)) totalAmountInSlabs;
    }

    /** 
    * @dev BetTypes
    * 0 for RedBlack, OddEven, HighLow => 18 numbers and reward = 1x the amount bet
    * 1 for Columns, Dozens => 12 numbers and reward = 2x the amount bet
    * 2 for Line => 6 numbers and reward = 5x the amount bet
    * 3 for Corner => 4 numbers and reward = 8x the amount bet
    * 4 for Street, ThreeNumBetsWithZero => 3 numbers and reward = 11x the amount bet
    * 5 for Split => 2 numbers and reward = 17x the amount bet
    * 6 for Number => 1 number and reward = 35x the amount bet
    */
    
    struct Bet{
        /**
        * @dev Differentiator 
        * for betType 0 => diff 0 for RedBlack, 1 for OddEven and 2 for HighLow
        * for betType 1 => diff 0 for columns and 1 for Dozens
        * for betType 2 => diff 0 for Line
        * for betType 3 => diff 0 for Corner
        * for betType 4 => diff 0 for Street and 1 for ThreeNumBetsWithZero
        * for betType 5 => diff 0 for Split
        * for betType 6 => diff 0 for Number
        */
        
        uint8 betType;
        uint8 differentiator;
        uint8[] numbers;
        uint256 amount;
    }

    struct RoundInfo{
        address user;
        uint256 epoch;
    }

    //Payout, MinBetAmount, MaxBetAmount by BetType
    mapping(uint8 => uint8) public payout;
    mapping(uint8 => uint256) public minBetAmount;
    mapping(uint8 => uint256) public maxBetAmount;
    //For each kind of bet, the required number of numbers to be bet on
    mapping(uint8 => uint8) public numbersByKindOfBet;
    //RoundInfo by roundId
    mapping(uint256 => RoundInfo) public roundInfo;
    //Round by userAddress amd Epoch 
    mapping(address => mapping(uint256 => Round)) public rounds;
    mapping(address => uint256) public currentUserEpoch;
    mapping(address => uint256) public claimCheckpoint;

    address public admin;
    address public operator;
    uint256 public counter;
    uint256 public treasuryAmount;
    uint256 private randomRoundId;
    uint256 public totalVolume;

    uint256 public randomNumUpdateAllowance; // seconds
    IRandomGenerator private randomGenerator;

    //Token which is used for betting
    address public tokenStaked;
    uint8 public tokenDecimals;

    event ExecuteRound(
        uint256 indexed roundId,
        address indexed user,
        uint256 indexed epoch,
        uint8 winningNumber,
        uint256 prevRoundIdForUser,
        uint256 totalAmountBet,
        uint256 totalRewards,
        uint256 treasuryCollections
        );
    event Claim(
        address indexed sender,
        uint256 indexed currentEpoch,
        uint256 amount
    );
    event ClaimAll(
        address indexed user, 
        uint256 claimCheckpoint, 
        uint256 reward
        );
    event ClaimTreasury(uint256 amount);
    event PayoutUpdated(
        uint256 indexed epoch,
        uint8[] indexed betType,
        uint8[] payout
    );
    event MinBetAmountUpdated(
        uint256 indexed epoch,
        uint8[] indexed betType, 
        uint256[] minBetAmount
        );
    event MaxBetAmountUpdated(
        uint256 indexed epoch,
        uint8[] indexed betType, 
        uint256[] maxBetAmount
        );
    event Pause(uint256 epoch);
    event Unpause(uint256 epoch);
    event OperatorChanged(address previousOperator, address newOperator);
    event OracleUpdateAllowanceUpdated(
        uint256 currentEpoch, 
        uint256 _randomNumUpdateAllowance
        );
    event TokenWithdrawal(address to, address token, uint256 amount);
    event NativeWithdrawal(address to, uint256 amount);
    event TokenStakedUpdated(uint256 epoch, address token, uint8 decimals);

    function initialize(
        bytes calldata data,
        address[] calldata _ownerAdminOperator
    ) public initializer {

        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        transferOwnership(_ownerAdminOperator[0]);
        admin = _ownerAdminOperator[1];
        operator = _ownerAdminOperator[2];

        numbersByKindOfBet[0] = 18;
        numbersByKindOfBet[1] = 12;
        numbersByKindOfBet[2] = 6;
        numbersByKindOfBet[3] = 4;
        numbersByKindOfBet[4] = 3;
        numbersByKindOfBet[5] = 2;
        numbersByKindOfBet[6] = 1;

        //Setting the bet payouts for different kinds of bets
        payout[0] = 1;
        payout[1] = 2;
        payout[2] = 5;
        payout[3] = 8;
        payout[4] = 11;
        payout[5] = 17;
        payout[6] = 35;        

        address _tokenStaked;
        uint8 _decimals;
        uint256 _randomNumUpdateAllowance;
        address _randomGenerator;
        
        (_tokenStaked, _decimals, _randomNumUpdateAllowance, _randomGenerator) 
            = abi.decode(
                    data, 
                    (address, uint8, uint256, address)
                );

        tokenStaked = _tokenStaked;
        tokenDecimals = _decimals;
        randomGenerator = IRandomGenerator(_randomGenerator);
        randomNumUpdateAllowance = _randomNumUpdateAllowance;

        //Setting min bet amounts and max bet amounts for each bet type
        //Min Bet is 1 token
        minBetAmount[0] = 10 ** _decimals;
        minBetAmount[1] = 10 ** _decimals;
        minBetAmount[2] = 10 ** _decimals;
        minBetAmount[3] = 10 ** _decimals;
        minBetAmount[4] = 10 ** _decimals;
        minBetAmount[5] = 10 ** _decimals;
        minBetAmount[6] = 10 ** _decimals;

        //Max bets for outside bets are 100 USDC
        //Max bets for inside bets are according to the payout!
        maxBetAmount[0] = 100 * 10 ** _decimals;
        maxBetAmount[1] = 80 * 10 ** _decimals;
        maxBetAmount[2] = 70 * 10 ** _decimals;
        maxBetAmount[3] = 60 * 10 ** _decimals;
        maxBetAmount[4] = 50 * 10 ** _decimals;
        maxBetAmount[5] = 40 * 10 ** _decimals;
        maxBetAmount[6] = 20 * 10 ** _decimals;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner(){}

    modifier onlyAdmin{
        require(msg.sender == admin, "admin: wut?");
        _;
    }

    modifier onlyOperator{
        require(msg.sender == operator, "operator: wut?");
        _;
    }

    modifier notContract{
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /**
     * @dev set admin address
     * callable by owner
     */
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        address previousAdmin = admin;
        admin = _admin;
        emit AdminChanged(previousAdmin, admin);
    }

    /**
     * @dev set operator address
     * callable by admin
     */
    function setOperator(address _operator) external onlyAdmin {
        require(_operator != address(0), "Cannot be zero address");
        address previousOperator = operator;
        operator = _operator;
        emit OperatorChanged(previousOperator, operator);
    }

    
    /**
     * @dev set token staked and its decimals
     * Callable by admin
     */
    function changeTokenStaked(address token, uint8 _decimals) 
        external 
        onlyAdmin 
    {
        tokenStaked = token;
        tokenDecimals = _decimals;

        emit TokenStakedUpdated(counter, token, _decimals);
    }
    
    
    /**
     * @dev get all the payouts
     */
    function getPayouts() external view returns(uint8[] memory){
        uint8[] memory payouts = new uint8[](7);
        for(uint8 i = 0; i < 7; i++){
            payouts[i] = payout[i];
        }
        return payouts;
    }

    /**
     * @dev get random number address
     * callable by owner, admin and operator
     */
    function getRandomNumberOracleAdd() external view returns(address){
        require(
            msg.sender == owner() || msg.sender == admin || msg.sender == operator,
            "Roulette: unauthorized access" 
            );
        return address(randomGenerator);
    }


    /**
     * @dev set random number address
     * callable by admin
     */
    function setRandomNumberOracleAdd(address _randomGenerator) external onlyAdmin {
        require(_randomGenerator != address(0), "Cannot be zero address");
        randomGenerator = IRandomGenerator(_randomGenerator);
    }


    /**
     * @dev set random number update allowance
     * callable by admin
     */
    function setRandomNumUpdateAllowance(uint256 _randomNumUpdateAllowance)
        external
        onlyAdmin
    {
        randomNumUpdateAllowance = _randomNumUpdateAllowance;
        emit OracleUpdateAllowanceUpdated(counter, _randomNumUpdateAllowance);
    }

    /**
     * @dev set payout rate
     * callable by admin
     */
    function setPayout(uint8[] calldata betType, uint8[] calldata _payout) external onlyAdmin {
        require(
            betType.length == _payout.length && betType.length <= 7,
            "Roulette: Array lengths mismatch"
            );

        for(uint8 i = 0; i < betType.length; i++){
            require(
                betType[i] < 7,
                "Roulette: betTypes can range between 0 and 6(included) only"
                );
            payout[betType[i]] = _payout[i];
        }

        emit PayoutUpdated(counter, betType, _payout);
    }

    /**
     * @dev set minBetAmount
     * callable by admin
     */
    function setMinBetAmount(
        uint8[] calldata betType, 
        uint256[] calldata _minBetAmount
        ) external 
        onlyAdmin 
    {
        require(
            betType.length == _minBetAmount.length && betType.length <= 7,
            "Roulette: Array lengths mismatch"
            );
        
        for(uint8 i = 0; i < betType.length; i++){
            
            require(
                betType[i] < 7,
                "Roulette: betTypes can range between 0 and 6(included) only"
                );

            require(
                _minBetAmount[i] <= maxBetAmount[betType[i]],
                "Roulette: minBetAmount should be <= maxBetAmount"
                );

            minBetAmount[betType[i]] = _minBetAmount[i];
        }

        emit MinBetAmountUpdated(counter, betType, _minBetAmount);
    }

    /**
     * @dev set maxBetAmount
     * callable by admin
     */
    function setMaxBetAmount(
        uint8[] calldata betType, 
        uint256[] calldata _maxBetAmount
        ) external 
        onlyAdmin 
    {
        require(
            betType.length == _maxBetAmount.length && betType.length <= 7,
            "Roulette: Array lengths mismatch"
            );
        
        for(uint8 i = 0; i < betType.length; i++){

            require(
                betType[i] < 7,
                "Roulette: betTypes can range between 0 and 6(included) only"
                );

            require(
                minBetAmount[betType[i]] <= _maxBetAmount[i],
                "Roulette: maxBetAmount should be >= minBetAmount"
                );
            
            maxBetAmount[betType[i]] = _maxBetAmount[i];
        }

        emit MaxBetAmountUpdated(counter, betType, _maxBetAmount);
    }

    /**
     * @dev gets random round id
     * callable by admin
     */
    function getRandomRoundId() public view returns(uint256){
        require(
            msg.sender == owner() || msg.sender == admin || msg.sender == operator,
            "Roulette: Unauthorized function call"
        );
        return randomRoundId;
    }


    /**
     * @dev Start the next round n, lock price for round n-1, end round n-2
     */
    function executeRound(
        Bet[] calldata bets
        ) 
        external 
        virtual 
        nonReentrant
        whenNotPaused 
    {
        counter = counter.add(1);
        currentUserEpoch[msg.sender] = currentUserEpoch[msg.sender].add(1);

        _startRound(msg.sender, currentUserEpoch[msg.sender]);

        uint8 randomNum = _getNumberFromOracle();
        _bet(msg.sender, bets);
        _endRound(msg.sender, currentUserEpoch[msg.sender], randomNum);
        _calculateRewards(msg.sender, currentUserEpoch[msg.sender]);

        roundInfo[counter] = RoundInfo(msg.sender, currentUserEpoch[msg.sender]);

        uint256 prevRoundIdForUser = 0;
        if(currentUserEpoch[msg.sender] > 1){
            prevRoundIdForUser = rounds[msg.sender][currentUserEpoch[msg.sender].sub(1)].roundId;
        }

        emit ExecuteRound(
            counter,
            msg.sender, 
            currentUserEpoch[msg.sender], 
            randomNum, 
            prevRoundIdForUser,
            rounds[msg.sender][currentUserEpoch[msg.sender]].totalAmountBet,
            rounds[msg.sender][currentUserEpoch[msg.sender]].totalRewardAmount,
            rounds[msg.sender][currentUserEpoch[msg.sender]].treasuryCollections
            );
    }

    function _startRound(address user, uint256 epoch) internal virtual{
        Round storage round = rounds[user][epoch];
        round.roundId = counter;
        round.epoch = epoch;
        round.totalAmountBet = 0;
    }


    /**
     * @dev End round
     */
    function _endRound(address user, uint256 epoch, uint8 winningNum) internal virtual{
        Round storage round = rounds[user][epoch];
        round.winningNumber = winningNum;
        round.oracleCalled = true;
    }

    /**
     * @dev Calculate rewards for round
     */
    function _calculateRewards(address user, uint256 epoch) internal virtual{
        require(
            rounds[user][epoch].totalRewardAmount == 0,
            "Rewards calculated"
        );
        Round storage round = rounds[user][epoch];
        uint8 winner = round.winningNumber;
        uint256 totalRewards = 0;
        uint256 treasuryAmt = 0;

        for(uint8 i = 0; i < 7; i++){
            totalRewards = totalRewards.add(round.totalAmountInSlabs[winner][payout[i]].mul(payout[i] + 1));
        }

        round.totalRewardAmount = totalRewards;
        if(totalRewards < round.totalAmountBet){
            treasuryAmt = (round.totalAmountBet).sub(totalRewards);
        }
        // Add to treasury
        round.treasuryCollections = treasuryAmt;
        treasuryAmount = treasuryAmount.add(treasuryAmt);

    }


    /**
     * @dev User bets
     */
    function _bet(
        address user,
        Bet[] calldata bets
        ) 
        internal 
        virtual
        whenNotPaused 
        notContract 
    {
        Round storage round = rounds[user][currentUserEpoch[msg.sender]];

        for(uint8 i = 0; i< bets.length; i++){
            
            round.bets.push(bets[i]);
            uint8 betType = bets[i].betType;
            uint8 differentiator = bets[i].differentiator;

            if(betType == 0){
                require(
                    differentiator == 0 || differentiator == 1 || differentiator == 2,
                    'Roulette: Invalid differentiator'
                    );
            }

            else if(betType == 1 || betType == 4){
                require(
                    differentiator == 0 || differentiator == 1,
                    'Roulette: Invalid differentiator'
                    );
            }

            else{
                require(
                    differentiator == 0,
                    'Roulette: Invalid differentiator'
                    );
            }

            require(betType < 7, "Roulette: betTypes can range between 0 and 6(included) only");

            require(
                bets[i].amount >= minBetAmount[betType] && bets[i].amount <= maxBetAmount[betType],
                "Roulette: Amount < MinBetAmount or Amount > MaxBetAmount for atleast one of the bets"
            );
            
            require(
                bets[i].numbers.length == numbersByKindOfBet[betType],
                "Roulette: invalid entry of numbers in atleast one bet"
                );

            uint8 slab = payout[betType];
            
            for(uint8 j = 0; j < bets[i].numbers.length; j++){
                round.totalAmountInSlabs[bets[i].numbers[j]][slab] = 
                    (round.totalAmountInSlabs[bets[i].numbers[j]][slab]).add(bets[i].amount);
            }
            round.totalAmountBet = (round.totalAmountBet).add(bets[i].amount);
            totalVolume = totalVolume.add(bets[i].amount);
        }

        IERC20Upgradeable(tokenStaked).safeTransferFrom(user, address(this), round.totalAmountBet);
        
    }

   
    function claim(uint256 epoch) external virtual notContract nonReentrant{
        require(!rounds[msg.sender][epoch].claimed, "Rewards claimed");

        (bool canClaim, uint256 reward) = claimable(msg.sender, epoch);
        
        require(canClaim || refundable(msg.sender, epoch), "Not claimable or refundable");
        
        if(refundable(msg.sender, epoch)){
            reward = rounds[msg.sender][epoch].totalAmountBet;
        }

        rounds[msg.sender][epoch].claimed = true;
        _safeTransferToken(address(msg.sender), reward);

        emit Claim(msg.sender, epoch, reward);
    }

    function claimAll() external virtual notContract nonReentrant{
        (bool isClaimable, uint256 reward) = totalClaimable(msg.sender);
        require(isClaimable, "Not claimable");
        _safeTransferToken(address(msg.sender), reward);
        claimCheckpoint[msg.sender] = currentUserEpoch[msg.sender];
        emit ClaimAll(msg.sender, currentUserEpoch[msg.sender], reward);
    }


    
    /**
     * @dev Claim all rewards in treasury
     * callable by admin
     */
    function claimTreasury() external virtual onlyAdmin{
        require(treasuryAmount > 0, "Zero treasury amount");
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        _safeTransferToken(admin, currentTreasuryAmount);
        emit ClaimTreasury(currentTreasuryAmount);
    }

    /**
     * @dev called by the admin to pause, triggers stopped state
     */
    function pause() public onlyAdmin whenNotPaused returns(bool){
        _pause();

        emit Pause(counter);
        return true;
    }

    /**
     * @dev called by the admin to unpause, returns to normal state
     * Reset genesis state. Once paused, the rounds would need to be kickstarted by genesis
     */
    function unpause() public onlyAdmin whenPaused returns(bool){
        _unpause();

        emit Unpause(counter);
        return true;
    }

    /**
     * @dev Get the claimable stats of specific epoch and user account
     */
    function claimable(address user, uint256 epoch) 
        public 
        virtual
        view 
        returns (bool, uint256) 
    {
        Round storage round = rounds[user][epoch];
        if(round.claimed){
            return (false, 0);
        }
        
        uint8 winningNum = round.winningNumber;
        uint256 winAmount = 0;
        for(uint8 i = 0; i < 7; i++){
            winAmount = winAmount.add((round.totalAmountInSlabs[winningNum][payout[i]]).mul(payout[i] + 1));
        }

        return
            ((
                round.oracleCalled && 
                winAmount > 0
            ),
             winAmount);
    }

    function totalClaimable(
        address user
        ) 
        public 
        virtual
        view 
        returns (bool, uint256) 
    {
        uint256 totalAmount;

        for(uint256 i = claimCheckpoint[user].add(1); i <= currentUserEpoch[user]; i++){
            if(!rounds[user][i].claimed){
                (bool canClaim, uint256 reward) = claimable(user, i);

                if(canClaim){
                    totalAmount = totalAmount.add(reward);
                }

                else if(refundable(user, i)){
                    totalAmount = totalAmount.add(rounds[user][i].totalAmountBet);
                }
            }
            
        }

        if(totalAmount == 0){
            return (false, 0);
        }
        
        return (true, totalAmount);
    }
    
    function refundable(address user, uint256 epoch) 
    public 
    virtual
    view 
    returns(bool){
        Round storage round = rounds[user][epoch];
        return 
            (round.totalAmountBet != 0) &&
            (!round.oracleCalled);
    }
    /**
     * @dev Get latest recorded price from oracle
     * If it falls below allowed buffer or has not updated, it would be invalid
     */
    function _getNumberFromOracle() internal returns (uint8) {
        uint256 allowedTime = block.timestamp.add(
            randomNumUpdateAllowance
        );
        (uint256 roundId, uint256 winner, uint256 timestamp) = 
            randomGenerator.latestRoundData(37);
        require(
            timestamp <= allowedTime,
            "Oracle update exceeded max allowance"
        );
        require(
            roundId >= randomRoundId,
            "Oracle update roundId < old id"
        );
        randomRoundId = roundId;
        return uint8(winner);
    }

    function _safeTransferToken(address to, uint256 value) internal {
        IERC20Upgradeable(tokenStaked).safeTransfer(to, value);
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }


    //If someone accidently sends tokens or native currency to this contract
    function withdrawAllTokens(address token) external onlyAdmin{
        uint256 bal = IERC20Upgradeable(token).balanceOf(address(this));
        withdrawToken(token, bal);
    }

    
    function withdrawToken(address token, uint256 amount) public virtual onlyAdmin{
        // require(token != tokenStaked, "Cannot withdraw the token staked");
        uint256 bal = IERC20Upgradeable(token).balanceOf(address(this));
        require(bal >= amount, "balanace of token in contract too low");
        IERC20Upgradeable(token).safeTransfer(admin, amount);
        emit TokenWithdrawal(admin, token, amount);
    }

    function withdrawAllNative() external onlyAdmin{
        uint256 bal = address(this).balance;
        withdrawNative(bal);
    } 

    function withdrawNative(uint256 amount) public virtual onlyAdmin{
        uint256 bal = address(this).balance;
        require(bal >= amount, "balanace of native token in contract too low");
        (bool sent, ) = admin.call{value: amount}("");
        require(sent, "Failure in native token transfer");
        emit NativeWithdrawal(admin, amount);
    }
}

