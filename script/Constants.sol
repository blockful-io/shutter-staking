pragma solidity 0.8.26;

address constant STAKING_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7; // shutter token
address constant CONTRACT_OWNER = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4; // shuter multisig
uint256 constant MIN_STAKE = 50_000e18;
uint256 constant REWARD_RATE = 0.1333333333e18;
uint256 constant LOCK_PERIOD = 182 days;
uint256 constant INITIAL_MINT = 10_000e18;

bytes32 constant DEPLOYMENT_SALT = keccak256("SHUTTER_STAKING");
