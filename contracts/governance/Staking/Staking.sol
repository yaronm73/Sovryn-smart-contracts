pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "./WeightedStaking.sol";

contract Staking is WeightedStaking{
    
    /**
     * @notice stakes the given amount for the given duration of time.
     * @dev only if staked balance is 0.
     * @param amount the number of tokens to stake
     * @param until timestamp indicating the date until which to stake
     * @param stakeFor the address to stake the tokens for or 0x0 if staking for oneself
     * @param delegatee the address of the delegatee or 0x0 if there is none.
     * */
    function stake(uint96 amount, uint until, address stakeFor, address delegatee) public {
        require(amount > 0, "Staking::stake: amount of tokens to stake needs to be bigger than 0");
        
        until = timestampToLockDate(until);
        require(until > block.timestamp, "Staking::timestampToLockDate: staking period too short");
    
        //stake for the msg.sender if not specified otherwise
        if(stakeFor == address(0))
            stakeFor = msg.sender;
        require(_currentBalance(stakeFor, until) == 0, "Staking:stake: use 'increaseStake' to increase an existing staked position");
        
        //do not stake longer than the max duration
        if (until > block.timestamp + MAX_DURATION)
            until = block.timestamp + MAX_DURATION;
            
        //retrieve the SOV tokens
        bool success = SOVToken.transferFrom(msg.sender, address(this), amount);
        require(success);
        
        //lock the tokens and update the balance by updating the user checkpoint
        _increaseUserStake(stakeFor, until, amount);
        
        //increase staked token count until the new locking date
        _increaseDailyStake(until, amount);
        
        //delegate to self in case no address provided
        if(delegatee == address(0))
            _delegate(stakeFor, stakeFor, until);
        else
            _delegate(stakeFor, delegatee, until);
        
        emit TokensStaked(stakeFor, amount, until, amount);
    }
    
    
    /**
     * @notice extends the staking duration until the specified date
     * @param previousLock the old unlocking timestamp
     * @param until the new unlocking timestamp in S
     * */
    function extendStakingDuration(uint previousLock, uint until) public{
        until = timestampToLockDate(until);
        require(previousLock <= until, "Staking::extendStakingDuration: cannot reduce the staking duration");
        
        //do not exceed the max duration, no overflow possible
        uint latest = block.timestamp + MAX_DURATION;
        if(until > latest)
            until = latest;
        
        //update checkpoints
        uint96 amount = getPriorUserStakeByDate(msg.sender, previousLock, block.number -1);
        require(amount > 0, "Staking::extendStakingDuration: nothing staked until the previous lock date");
        _decreaseDailyStake(previousLock, amount);
        _increaseDailyStake(until, amount);
        _decreaseUserStake(msg.sender, until, amount);
        _increaseUserStake(msg.sender, until, amount);
        //delegate might change: if there is already a delegate set for the until date, it will remain the delegate for this position
        address delegateFrom = delegates[msg.sender][previousLock];
        address delegateTo = delegates[msg.sender][until];
        if(delegateTo == address(0)){
            delegateTo = delegateFrom;
            delegates[msg.sender][until] = delegateFrom;
        }
        delegates[msg.sender][previousLock] = address(0);
        _decreaseDelegateStake(delegateFrom, previousLock, amount);
        _increaseDelegateStake(delegateTo, until, amount);
        
        
        emit ExtendedStakingDuration(msg.sender, previousLock, until);
    }
    
    /**
     * @notice increases a users stake
     * @param amount the amount of SOV tokens
     * @param stakeFor the address for which we want to increase the stake. staking for the sender if 0x0
     * @param until the lock date until which the funds are staked
     * */
    function increaseStake(uint96 amount, address stakeFor, uint until) public{
        require(amount > 0, "Staking::increaseStake: amount of tokens to stake needs to be bigger than 0");
        until = timestampToLockDate(until);
        uint96 balance = _currentBalance(stakeFor, until);
        require(balance > 0, "Staking:increaseStake: nothing staked yet until the given date. Use 'stake' instead.");
        
        //retrieve the SOV tokens
        bool success = SOVToken.transferFrom(msg.sender, address(this), amount);
        require(success);
        
        //stake for the msg.sender if not specified otherwise
        if(stakeFor == address(0))
            stakeFor = msg.sender;
        
        //increase staked balance
        balance = add96(balance, amount, "Staking::increaseStake: balance overflow");
        
        //update checkpoints
        _increaseDailyStake(until, amount);
        _increaseDelegateStake(delegates[stakeFor][until], until, amount);
        _increaseUserStake(stakeFor, until, amount);
        
        emit TokensStaked(stakeFor, amount, until, balance);
    }
    
    /**
     * @notice withdraws the given amount of tokens if they are unlocked
     * @param amount the number of tokens to withdraw
     * @param until the date until which the tokens were staked
     * @param receiver the receiver of the tokens. If not specified, send to the msg.sender
     * */
    function withdraw(uint96 amount, uint until, address receiver) public {
        require(amount > 0, "Staking::withdraw: amount of tokens to be withdrawn needs to be bigger than 0");
        require(block.timestamp >= until || allUnlocked, "Staking::withdraw: tokens are still locked.");
        uint96 balance = getPriorUserStakeByDate(msg.sender, until, block.number -1);
        require(amount <= balance, "Staking::withdraw: not enough balance");
        
        //determine the receiver
        if(receiver == address(0))
            receiver = msg.sender;
            
        //reduce staked balance
        uint96 newBalance = sub96(balance, amount, "Staking::withdraw: balance underflow");

        //update the checkpoints
        _decreaseDailyStake(until, amount);
        _decreaseUserStake(msg.sender, until, amount);
        
        //transferFrom
        bool success = SOVToken.transfer(receiver, amount);
        require(success, "Staking::withdraw: Token transfer failed");
        
        emit TokensWithdrawn(msg.sender, receiver, amount);
    }
    
    /**
     * @notice allow the owner to unlock all tokens in case the staking contract is going to be replaced
     * note: not reversible on purpose. once unlocked, everything is unlocked. the owner should not be able to just quickly
     * unlock to withdraw his own tokens and lock again.
     * */
    function unlockAllTokens() public onlyOwner{
        allUnlocked = true;
        emit TokensUnlocked(SOVToken.balanceOf(address(this)));
    }
    
    /**
     * @notice returns the current balance of for an account locked until a certain date
     * @param account the user address
     * @param lockDate the lock date
     * @return the lock date of the last checkpoint
     * */
    function _currentBalance(address account, uint lockDate) internal view returns(uint96) {
        return userStakingCheckpoints[account][lockDate][numUserStakingCheckpoints[account][lockDate] - 1].stake;
    }
    
    /**
     * @notice Get the number of staked tokens held by the `account`
     * @param account The address of the account to get the balance of
     * @return The number of tokens held
     */
    function balanceOf(address account) public view returns (uint96 balance) {
        for (uint i = kickoffTS; i <= block.timestamp + MAX_DURATION; i += TWO_WEEKS){
            balance = add96(balance, _currentBalance(account, i), "Staking::balanceOf: overflow");
        }
    }


    /**
     * @notice Delegate votes from `msg.sender` which are locked until lockDate to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param lockDate the date if the position to delegate
     */
    function delegate(address delegatee, uint lockDate) public {
        return _delegate(msg.sender, delegatee, lockDate);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param lockDate the date until which the position is locked
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(address delegatee, uint lockDate, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, lockDate, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Staking::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "Staking::delegateBySig: invalid nonce");
        require(now <= expiry, "Staking::delegateBySig: signature expired");
        return _delegate(signatory, delegatee, lockDate);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint96) {
        return getPriorVotes(account, block.number - 1, block.timestamp);
    }
    
    /**
     * @notice gets the current number of tokens staked for a day
     * @param lockedTS the timestamp to get the staked tokens for
     * */
    function getCurrentStakedUntil(uint lockedTS) external view returns (uint96) {
        uint32 nCheckpoints = numTotalStakingCheckpoints[lockedTS];
        return nCheckpoints > 0 ? totalStakingCheckpoints[lockedTS][nCheckpoints - 1].stake : 0;
    }
    

    function _delegate(address delegator, address delegatee, uint lockedTS) internal {
        address currentDelegate = delegates[delegator][lockedTS];
        uint96 delegatorBalance = _currentBalance(delegator, lockedTS);
        delegates[delegator][lockedTS] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance, lockedTS);
    }
    

    function _moveDelegates(address srcRep, address dstRep, uint96 amount, uint lockedTS) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0))
                 _decreaseDelegateStake(srcRep, lockedTS, amount);
                 
            if (dstRep != address(0))
                _increaseDelegateStake(dstRep, lockedTS, amount);
        }
    }
    

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}