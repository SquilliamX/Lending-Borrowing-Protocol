// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CoreStorage is ReentrancyGuard {
    ///////////////////////////////
    //           Errors          //
    ///////////////////////////////
    error LendingEngine__NeedsMoreThanZero();
    error LendingEngine__YouNeedMoreFunds();
    error LendingEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error LendingEngine__TokenNotAllowed(address token);
    error LendingEngine__TransferFailed();
    error LendingEngine__BreaksHealthFactor(uint256);
    error BorrowingEngine__TransferFailed();
    error BorrowingEngine__NotEnoughBorrowedAmount();
    error BorrowingEngine__ZeroAddressNotAllowed();
    error LendingEngine__NotEnoughAvailableTokens();

    // Tracks how much collateral each user has deposited
    // First key: user's address
    // Second key: token address they deposited
    // Value: amount of that token they have deposited
    mapping(address user => mapping(address token => uint256 amount)) internal s_collateralDeposited;
    // an array of all the collateral tokens users can use.
    address[] internal s_collateralTokens;

    mapping(address user => uint256 amountBorrowed) internal s_AmountBorrowed;

    ///////////////////
    //     Type     //
    //////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////////////
    //      State Variables      //
    ///////////////////////////////

    // Chainlink price feeds return prices with 8 decimal places
    // To maintain precision when working with USD values, we add 10 more decimal places
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    uint256 private constant LIQUIDATION_PRECISION = 100;

    uint256 private constant PRECISION = 1;

    uint256 private constant MIN_HEALTH_FACTOR = 1;

    uint256 private constant LIQUIDATION_BONUS = 10;

    // tracks the balances of users
    mapping(address user => uint256 amountUserHas) private s_balances;

    // maps token address to pricefeed addresses
    mapping(address token => address priceFeed) private s_priceFeeds;

    // Track borrowed amounts per user per token
    mapping(address user => mapping(address token => uint256 amount)) private s_tokenBorrowed;

    ///////////////////////////////
    //           Events          //
    ///////////////////////////////

    // Event emitted when collateral is deposited, used for:
    // 1. Off-chain tracking of deposits
    // 2. DApp frontend updates
    // 3. Cheaper storage than writing to state
    // `indexed` parameters allow efficient filtering/searching of logs
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    event UserBorrowed(address indexed user, address indexed token, uint256 indexed amount);

    event BorrowedAmountRepaid(
        address indexed payer, address indexed onBehalfOf, address indexed token, uint256 amount
    );

    ///////////////////////////////
    //         Modifiers         //
    ///////////////////////////////

    // modifier to make sure that the amount being passes as the input is more than 0 or the function being called will revert.
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingEngine__NeedsMoreThanZero();
        }
        _;
    }

    // Modifier that checks if a token is in our list of allowed collateral tokens
    // If a token has no price feed address (equals address(0)) in our s_priceFeeds mapping,
    // it means it's not an allowed token and the transaction will revert
    // The underscore (_) means "continue with the function code if check passes"
    modifier isAllowedToken(address token) {
        if (getPriceFeeds()[token] == address(0)) {
            revert LendingEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////////////////
    //         Functions         //
    ///////////////////////////////

    /* 
     * @param: tokenCollateralAddress is the token(address) users are depositing
     * @param: amountCollateral is the amount of they are depositing
     * @dev: Users main entry point to interact with the system.
    */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses) {
        // if the amount of tokenAddresses is different from the amount of priceFeedAddresses, then revert
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert LendingEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // loop through the tokenAddresses array and count it by 1s
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            // and we set each tokenAddress equal to their respective priceFeedAddresses in the mapping.
            // we declare this in the constructor and define the variables in the deployment script
            getPriceFeeds()[tokenAddresses[i]] = priceFeedAddresses[i];
            // push all the tokens into our tokens array/list
            s_collateralTokens.push(tokenAddresses[i]);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        // gets the priceFeed of the token inputted by the user and saves it as a variable named priceFeed of type AggregatorV3Interface
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // out of all the data that is returned by the pricefeed, we only want to save the price
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Calculate USD value while handling decimal precision:
        // 1. Convert price to uint256 and multiply by ADDITIONAL_FEED_PRECISION(1e10(add 10 zeros for precision)) to match token decimals
        // 2. Multiply by the token amount
        // 3. Divide by PRECISION(1e18(for precision)) to get the final USD value with correct decimal places
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getTotalCollateralOfToken(address token) internal view returns (uint256 totalCollateral) {
        // loop through the allowed collateral tokens
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // if the token inputted by the caller is in the loop, then
            if (s_collateralTokens[i] == token) {
                // Get actual token balance of contract
                totalCollateral = IERC20(token).balanceOf(address(this));
                // exit loop immediately
                break;
            }
        }
        // return the total amount of collateral of these tokens
        return totalCollateral;
    }

    function getAvailableToBorrow(address token) internal view returns (uint256) {
        // Get total amount of this token deposited as collateral
        uint256 totalCollateral = getTotalCollateralOfToken(token);

        // Get total amount already borrowed of this token
        uint256 totalBorrowed = getTotalBorrowedOfToken(token);

        // Available = Total Collateral - Total Borrowed
        return totalCollateral - totalBorrowed;
    }

    function getTotalBorrowedOfToken(address token) internal view returns (uint256 totalBorrowed) {
        // loop through the allowed collateral tokens
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // if the token inputted by the caller is in the loop, then
            if (s_collateralTokens[i] == token) {
                // Sum up all borrowed amounts of this token across users
                for (uint256 j = 0; j < s_collateralTokens.length; j++) {
                    totalBorrowed += getTokenBorrowed()[msg.sender][token];
                }
                // exit loop immediately
                break;
            }
        }
        // return the total amount borrowed of these tokens
        return totalBorrowed;
    }

    function getMinimumHealthFactor() internal pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getPrecision() internal pure returns (uint256) {
        // Returns the precision scalar used for calculations (1e18)
        return PRECISION;
    }

    function getAdditionalFeedPrecision() internal pure returns (uint256) {
        // Returns additional precision scalar for price feeds (1e10)
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        // Returns the liquidation threshold (50 = 50% of collateral value used for health factor)
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() internal pure returns (uint256) {
        // Returns bonus percentage liquidators get when liquidating (10 = 10% bonus)
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() internal pure returns (uint256) {
        // Returns precision scalar for liquidation calculations (100)
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        // Returns minimum health factor before liquidation (1e18 = 1)
        return MIN_HEALTH_FACTOR;
    }

    // Returns the array of all allowed collateral token addresses
    // This is useful for:
    // 1. UI interfaces to know which tokens can be used as collateral
    // 2. Other contracts that need to interact with the system
    // 3. Checking which tokens are supported without accessing state variables directly
    function getCollateralTokens() external view returns (address[] memory) {
        // Returns array of all accepted collateral token addresses
        return s_collateralTokens;
    }

    // Returns the Chainlink price feed address for a given collateral token
    // Used for:
    // 1. Verifying price feed sources
    // 2. External systems that need to access the same price data
    // 3. Debugging and auditing price feed configurations
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        // Returns Chainlink price feed address for given collateral token
        return s_priceFeeds[token];
    }

    function getBorrowedAmountsOfToken(address token) external view returns (uint256) {
        return s_tokenBorrowed[msg.sender][token];
    }

    function getPriceFeeds() internal view returns (mapping(address => address) storage) {
        return s_priceFeeds;
    }

    function balanceOf(address account) public view returns (uint256) {
        return s_balances[account];
    }

    function getTokenBorrowed() internal view returns (mapping(address => mapping(address => uint256)) storage) {
        return s_tokenBorrowed;
    }
}
