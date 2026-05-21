// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    // ---------------------------- STATE VARIABLES ----------------------------
    using SafeERC20 for IERC20;
    // ---------------------------- CUSTOM ERRORS ----------------------------
    // Custom errors for invalid inputs and conditions.
    // Using named errors is more gas-efficient than string messages.
    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();

    IERC20 public immutable baseToken; // PNPToken
    IERC20 public immutable quoteToken; // FNBToken

    struct Order {
        address trader;
        uint8 isBuy; // 0 = buy, 1 = sell
        uint256 price;
        uint256 amount;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    // ---------------------------- EVENTS ----------------------------
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint8 isBuy,
        address tokenIn, // token the trader gives
        address tokenOut, // token the trader receives
        uint256 amount,
        uint256 price
    );
    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address buyer,
        address seller,
        uint256 amount,
        uint256 price
    );
    event OrderCanceled(uint256 indexed orderId, address indexed trader);
    // ---------------------------- CONSTRUCTOR ----------------------------
    // Constructor saves the addresses of the two tokens that are going to be traded
    constructor(address _tokenA, address _tokenB) {
        // require makes sure that neither address is a zero address (this would be invalid)
        require(_tokenA != address(0) && _tokenB != address(0), "Zero address is not allowed");
        // Store the two token addresses (PNPT = base, FNBT = quote)
        baseToken = IERC20(_tokenA);
        quoteToken = IERC20(_tokenB);
    }
    // ---------------------------- ORDER CREATION ----------------------------
    // Allow a user to create a buy order for baseToken using quoteToken as payment.
    // The user must specify:
    //      - amount = how many baseToken they want to buy (in baseToken units)
    //      - price  = the maximum quoteToken per baseToken they are willing to pay (scaled by 1e18)
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Amount must be greater than 0 AND the price must be greater than 0
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Calculates the total quoteToken cost.
        // amount is in the token's smallest unit (like wei for Ether)
        // because the token was minted with 18 extra digits.
        // price is a plain integer: the number of quoteToken per whole baseToken.
        // Multiplying price by amount gives the correct quoteToken amount in its smallest units.
        uint256 cost = (price * amount);

        // Take the quoteToken from the buyer and hold it in this contract
        quoteToken.safeTransferFrom(msg.sender, address(this), cost);

        // Creates a new order with a unique ID
        orderId = nextOrderId;
        nextOrderId = nextOrderId + 1;

        // Store the order details
        orders[orderId] = Order({ trader: msg.sender, isBuy: 0, price: price, amount: amount });
        emit OrderPlaced(orderId, msg.sender, 0, address(quoteToken), address(baseToken), amount, price); // Emit an event so that off‑chain apps know a new order was created
    }

    // Allow a user to create a sell order for baseToken(s), asking for quoteToken(s) in return.
    // The user must specify:
    //      - amount = how many baseToken they want to sell (in baseToken units)
    //      - price  = the minimum quoteToken per baseToken they want to receive (scaled by 1e18)
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Amount must be greater than 0 AND the price must be greater than 0
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Take the baseToken from the seller and hold it in this contract.
        // No division by 1e18 is needed here because the seller sends the exact amount of baseToken
        // that they want to sell. The price is only stored and will only be used later in matchOrders
        // to calculate how many quoteToken the seller should receive (which will require the division).
        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        // Create a new order with a unique ID
        orderId = nextOrderId;
        nextOrderId = nextOrderId + 1;

        // Store the order details (isBuy is false because this is a sell)
        orders[orderId] = Order({ trader: msg.sender, isBuy: 1, price: price, amount: amount });
        // Emit an event so off-chain apps know a sell order was created
        emit OrderPlaced(orderId, msg.sender, 1, address(baseToken), address(quoteToken), amount, price);
    }
    // ---------------------------- ORDER MATCHING ----------------------------
    // Match an existing buy order with an existing sell order.
    // Anyone can call this and it does not have to be the order creators.
    // The two orders must have compatible prices (buy price >= sell price).
    // The smaller amount is fully matched; the larger order keeps the remainder.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        // Fetch the two orders from storage
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        // require: the orders exist and are of the correct type
        require(buyOrder.isBuy == 0, "First order must be a buy order");
        require(sellOrder.isBuy == 1, "Second order must be a sell order");
        // require: both orders still have some amount left to fill
        require(buyOrder.amount > 0, "Buy order already filled");
        require(sellOrder.amount > 0, "Sell order already filled");
        // require: the buyer's price must be at least the seller's price.
        // If the buyer is offering less than the seller wants, the trade cannot happen.
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();
        // Work out how many baseToken can be traded — the smaller of the two remaining amounts
        uint256 matchAmount = buyOrder.amount < sellOrder.amount ? buyOrder.amount : sellOrder.amount;

        // Calculates how many quoteToken the seller should receive.
        // The price used is the sell order's price (the buyer gets a better or equal price).
        // matchAmount is in baseToken's smallest units (18 extra digits, because of how the token was minted).
        // price is a plain integer (quoteToken per whole baseToken).
        // Multiplying them gives the correct quoteToken amount in its smallest units.
        uint256 quoteAmount = matchAmount * sellOrder.price;

        // require: the trade must be large enough that the seller gets at least 1 smallest unit of quoteToken.
        // If the calculation rounds down to zero, the buyer would get baseToken but the seller would get nothing.
        require(quoteAmount > 0, "Trade too small - no quoteToken would be transferred");

        // Transfer baseToken from the contract (which holds the seller's tokens) to the buyer
        baseToken.safeTransfer(buyOrder.trader, matchAmount);

        // Transfer quoteToken from the contract (which holds the buyer's payment) to the seller
        quoteToken.safeTransfer(sellOrder.trader, quoteAmount);

        // Update the remaining amounts for both orders
        buyOrder.amount -= matchAmount;
        sellOrder.amount -= matchAmount;

        // Emit an event to record the match
        emit OrderMatched(buyOrderId, sellOrderId, buyOrder.trader, sellOrder.trader, matchAmount, sellOrder.price);
    }
    // ---------------------------- ORDER CANCELLATION ----------------------------
    // Allow the creator of an order to cancel the order and get their tokens back.
    // Only unfilled or partially filled orders can be cancelled.
    // The contract returns the tokens that were locked when the order was placed.
    function cancelOrder(uint256 orderId) external {
        // Fetch the order from storage
        Order storage order = orders[orderId];

        // require: only the person who created the order may cancel it
        if (order.trader != msg.sender) revert UnauthorizedCancellation(); // require: the order must still have some amount left, otherwise it is already filled or cancelled
        require(order.amount > 0, "Order already filled or cancelled");

        if (order.isBuy == 0) {
            // For a buy order, the buyer's quoteToken is held by the contract.
            // Calculates the quoteToken amount to refund: price * the remaining amount.
            // amount is in baseToken smallest units (18 digits because of the mint).
            // price is a plain integer (quoteToken per whole baseToken).
            // Multiplying them gives the refund in quoteToken smallest units.
            uint256 refund = order.price * order.amount;
            quoteToken.safeTransfer(msg.sender, refund);
        } else {
            // For a sell order, the seller's baseToken is held by the contract.
            // Refund the exact remaining baseToken amount (no division is needed here).
            baseToken.safeTransfer(msg.sender, order.amount);
        }

        // Mark the order as cancelled by setting its remaining amount to zero
        order.amount = 0;

        // Emit an event so off‑chain apps know the order was cancelled
        emit OrderCanceled(orderId, msg.sender);
    }

    // ---------------------------- QUERY FUNCTIONS ----------------------------
    // Returns how many baseToken are still remaining in an order.
    // If the order was completely matched or cancelled, the result will be 0.
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].amount;
    }
    // Returns whether an order is still open (has a positive remaining amount).
    // The test uses this to verify that orders are fully filled or cancelled.
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].amount > 0;
    }
}
