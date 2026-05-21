// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract RewardTokensManager is Ownable {
    // ---------------------------- STATE VARIABLES ----------------------------
    // Attach the PoolId library to PoolKey so poolKey.toId() can be called
    using PoolIdLibrary for PoolKey;

    // Pool parameters that never change
    // Fee 3000 means the pool charges a 0.3% fee on every swap
    uint24 public constant FEE_TIER = 3000;
    // Tick spacing 60 is the standard Uniswap spacing for a 0.3% fee pool
    int24 public constant TICK_SPACING = 60;
    // No hooks means the pool behaves like a standard Uniswap pool with no extra features
    address public constant HOOKS = address(0);

    // The Uniswap v4 contracts that this manager interacts with
    IPoolManager public immutable poolManager; // used to initialise the pool
    IPositionManager public immutable positionManager; // used to mint liquidity positions

    // The two ERC20 tokens that form the pool
    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;

    // Tokens sorted by address (Uniswap requires this to avoid duplicate pools for the same pair)
    Currency public currency0;
    Currency public currency1;

    // The unique identifier of the pool after it is created
    bytes32 public poolId;

    // Keeps a record of which pool IDs have already been created,
    // so the same pool cannot be initialised twice.
    mapping(bytes32 => bool) public createdPools;

    // ---------------------------- EVENTS ----------------------------
    // Emitted when a pool is successfully created
    event PoolCreated(
        bytes32 indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    // Emitted after a liquidity position is minted
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    );

    // ---------------------------- CUSTOM ERRORS ----------------------------
    // Reverted if the mint tick range does not include the required price
    error TickRangeDoesNotCoverAssignmentPrice();

    // ---------------------------- CONSTRUCTOR ----------------------------
    // Constructor saves the Uniswap contract addresses and the two token addresses.
    // The deployer is set as the owner (Ownable).
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        // require: none of the Uniswap contract addresses can be a zero address
        require(_poolManager != address(0), "PoolManager address cannot be zero");
        require(_positionManager != address(0), "PositionManager address cannot be zero");

        // require: both token addresses must be valid (not zero)
        require(_pnpToken != address(0) && _fnbToken != address(0), "Token address cannot be zero");

        // Store the PoolManager and PositionManager so they can be called up later
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);

        // Store the two tokens that will make up the pool
        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);

        // Uniswap requires tokens to be sorted by address.
        // This avoids creating two different pool IDs for the same pair.
        // The sorted tokens are saved as currency0 and currency1.
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
    }

    // ---------------------------- PUBLIC VIEW FUNCTIONS ----------------------------
    // Returns the two tokens in the sorted order that Uniswap expects.
    function getCanonicalCurrencies() external view returns (Currency, Currency) {
        return (currency0, currency1);
    }

    // Returns the tick that matches the fixed exchange rate of 1 FNBT = 10 PNPT.
    // The price is expressed as currency1 per currency0, so the value depends on
    // which token is sorted first (the lower address).
    //
    // Uniswap stores prices as sqrtPriceX96 = sqrt(price) * 2^96.
    // The two possible prices are 0.1 and 10.
    // The constants used here were calculated off‑chain by taking
    //   sqrt(0.1) * 2^96   and   sqrt(10) * 2^96 .
    function getTargetTick() public view returns (int24) {
        if (currency0 == Currency.wrap(address(pnpToken))) {
            // If PNPT is currency0 → price = 0.1 (FNBT per PNPT)
            // sqrt(0.1) * 2^96 ≈ 25054144837504793141305103903
            uint160 sqrtPriceX96 = 25054144837504793141305103903;
            return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        } else {
            // If FNBT is currency0 → price = 10 (PNPT per FNBT)
            // sqrt(10) * 2^96 ≈ 250541448375047931413051039033
            uint160 sqrtPriceX96 = 250541448375047931413051039033;
            return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        }
    }
    // Returns the ID of the pool that was created by this contract.
    // poolId is set in createPool().
    function getPoolId() public view returns (bytes32) {
        return poolId;
    }

    // ---------------------------- POOL CREATION ----------------------------
    // Creates a Uniswap v4 pool for the two reward tokens.
    // The caller provides the starting price as sqrtPriceX96.
    // onlyOwner restricts this action to the contract deployer so the pool cannot be re‑created or altered by anyone else.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 _poolId) {
        // Builds the pool key that uniquely identifies this pool.
        // The tokens are always in sorted order (by address), which is the exact order Uniswap expects.
        // The key also includes the fee tier, the tick spacing and the hooks address (which here is none).
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        // This asks the PoolManager to register the pool.
        // key.toId() gives the pool's unique identifier.
        _poolId = PoolId.unwrap(key.toId());
        poolManager.initialize(key, sqrtPriceX96);
        // Stores the pool ID so other functions can use it
        poolId = _poolId;
        // Marks this pool as created so it cannot be created again
        createdPools[_poolId] = true;
        // Emit an event so off-chain apps know a pool was created
        emit PoolCreated(_poolId, currency0, currency1, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    // ---------------------------- LIQUIDITY MINTING ----------------------------
    // Mints a concentrated liquidity position in the pool.
    // The caller specifies:
    //   - tickLower and tickUpper: the price range where liquidity will be active
    //   - amount0Desired and amount1Desired: how many of each token are to be added
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 _positionId, bytes32 _poolId) {
        // require: at least one of the desired amounts must be greater than zero
        require(amount0Desired > 0 || amount1Desired > 0, "Must provide at least one token amount");

        // Checks that the chosen tick range includes the target price (1 FNBT = 10 PNPT).
        // The target tick is determined by which token is currency0.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || targetTick > tickUpper) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }
        // This pulls the desired token amounts from the caller into this contract.
        // The caller must have called approve() on each token before calling this function.
        if (amount0Desired > 0) {
            IERC20(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1Desired);
        }

        // Gets the pool's current price (sqrtPriceX96) because it is needed to
        // calculate how much liquidity the provided tokens will produce.
        // The empty commas tell Solidity to ignore the other three values.
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));

        // Converts the tick boundaries into sqrt prices, which is required by the liquidity helper.
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        // Computes the maximum liquidity that the desired token amounts can support,
        // given the pool's current price and the chosen tick range.
        // The result (liquidity) is the "L" value that measures how much the position contributes to the pool.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            amount0Desired,
            amount1Desired
        );
        // The PositionManager stores the Permit2 address, but the IPositionManager
        // interface does not expose it. A low‑level staticcall is used to retrieve it.
        (bool success, bytes memory data) = address(positionManager).staticcall(abi.encodeWithSignature("permit2()"));
        require(success, "Failed to get permit2 address");
        address permit2 = abi.decode(data, (address));
        // Grant Permit2 unlimited ERC‑20 approval so it can call transferFrom
        // on both token contracts. This is the standard ERC‑20 allowance.
        IERC20(Currency.unwrap(currency0)).approve(permit2, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(permit2, type(uint256).max);

        // Encodes the MINT_POSITION action into raw bytes so the PositionManager can process it.
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        // The PositionManager expects one parameter blob per action.
        // Two actions are being requested (mint and settle), so the array holds two blobs.
        bytes[] memory params = new bytes[](2);

        // Builds the parameters for the mint. This tells the PositionManager:
        //   - which pool to add liquidity to (the pool key)
        //   - the price range (tickLower, tickUpper)
        //   - how much liquidity to create (the liquidity amount returned by getLiquidityForAmounts)
        //   - the maximum token amounts to spend (amount0Desired, amount1Desired)
        //   - who will own the new position (msg.sender)
        //   - any extra data for hooks (empty, because no hooks are attached)
        params[0] = abi.encode(
            PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: FEE_TIER,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            }),
            tickLower,
            tickUpper,
            liquidity,
            amount0Desired,
            amount1Desired,
            msg.sender,
            ""
        );
        // Parameters for the SETTLE_PAIR action: tells the PositionManager which two tokens
        // (currency0 and currency1) must be transferred from this contract to complete the mint.
        params[1] = abi.encode(currency0, currency1);

        // The PositionManager assigns the next token ID to this new position.
        _positionId = positionManager.nextTokenId();
        // The deadline of block.timestamp + 300 seconds (5 minutes) gives the transaction time to be
        // mined on the chain, yet prevents an old mint from executing with an outdated price.
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        // Returns any remaining token balance back to the caller.
        // This is necessary even though the full desired amounts were approved before because the PositionManager
        // might not consume them all, leaving a small balance that belongs to the user.
        uint256 dust0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        if (dust0 > 0) {
            IERC20(Currency.unwrap(currency0)).transfer(msg.sender, dust0);
        }
        uint256 dust1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        if (dust1 > 0) {
            IERC20(Currency.unwrap(currency1)).transfer(msg.sender, dust1);
        }

        // Return the pool ID to the caller.
        _poolId = poolId;

        // Emits an event so off‑chain apps know liquidity was minted.
        emit LiquidityMinted(poolId, _positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}
