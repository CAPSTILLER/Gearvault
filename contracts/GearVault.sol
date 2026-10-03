// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title GearVault
/// @notice Holds GEAR tokens (6 decimals) and lets trusted "operator" wallets (game backends)
///         pay small amounts out to players. The owner (cold wallet) controls everything else.
/// @dev All amounts are in the token's smallest unit. GEAR has 6 decimals, so 1 GEAR = 1_000_000.
///      Safety model: if an operator key is stolen, the most the thief can take is `dailyCap`
///      per UTC day, and the owner can pause the vault at any time.
contract GearVault {
    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice The GEAR token this vault pays out. Fixed forever at deployment.
    IERC20 public immutable gearToken;

    /// @notice The owner (should be the cold wallet). Can change settings and move funds.
    address public owner;

    /// @notice Address that has been offered ownership but has not accepted yet (0 if none).
    address public pendingOwner;

    /// @notice Largest amount a single dispense() call can pay out. (50 GEAR = 50_000_000)
    uint256 public maxDispense;

    /// @notice Largest total amount all dispense() calls together can pay out per UTC day.
    ///         (10,000 GEAR = 10_000_000_000)
    uint256 public dailyCap;

    /// @notice Largest total one recipient wallet can receive from dispense() per UTC day.
    ///         0 means this limit is switched off.
    uint256 public perWalletDailyCap;

    /// @notice When true, dispense() is blocked. Owner functions still work.
    bool public paused;

    /// @notice True for wallets allowed to call dispense().
    mapping(address => bool) public isOperator;

    /// @notice Day number (block.timestamp / 1 days) that `dispensedToday` refers to.
    uint256 public currentDay;

    /// @notice Total paid out by dispense() during `currentDay`.
    uint256 public dispensedToday;

    /// @dev recipient => day number => amount received from dispense() that day.
    mapping(address => mapping(uint256 => uint256)) private _walletDispensed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Dispensed(address indexed operator, address indexed recipient, uint256 amount);
    event OperatorAuthorized(address indexed operator);
    event OperatorRevoked(address indexed operator);
    event MaxDispenseUpdated(uint256 oldLimit, uint256 newLimit);
    event DailyCapUpdated(uint256 oldCap, uint256 newCap);
    event PerWalletDailyCapUpdated(uint256 oldCap, uint256 newCap);
    event PauseToggled(bool indexed isPaused);
    event GearWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, uint256 amount, address indexed to);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotOperator();
    error NotPendingOwner();
    error NoPendingOwner();
    error ContractPaused();
    error ExceedsMaxDispense();
    error ExceedsDailyCap();
    error ExceedsWalletDailyCap();
    error InsufficientVaultBalance();
    error ZeroAddress();
    error TransferFailed();
    error CannotRescueGear();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _gearToken GEAR token address (Base: 0x5880cD05605A549f1DAb01a53ca61Ee559244bD1).
    /// @param _initialOwner Owner from the very first block (the cold wallet). The deployer gets no rights.
    /// @param _initialOperator First operator (the hot wallet that will call dispense()).
    /// @param _initialMaxDispense Per-call limit, e.g. 50_000_000 = 50 GEAR.
    /// @param _initialDailyCap Total per-day limit, e.g. 10_000_000_000 = 10,000 GEAR.
    constructor(
        address _gearToken,
        address _initialOwner,
        address _initialOperator,
        uint256 _initialMaxDispense,
        uint256 _initialDailyCap
    ) {
        if (_gearToken == address(0) || _initialOwner == address(0) || _initialOperator == address(0)) {
            revert ZeroAddress();
        }

        gearToken = IERC20(_gearToken);
        owner = _initialOwner;
        maxDispense = _initialMaxDispense;
        dailyCap = _initialDailyCap;
        currentDay = block.timestamp / 1 days;

        isOperator[_initialOperator] = true;

        emit OwnershipTransferred(address(0), _initialOwner);
        emit OperatorAuthorized(_initialOperator);
        emit MaxDispenseUpdated(0, _initialMaxDispense);
        emit DailyCapUpdated(0, _initialDailyCap);
    }

    // ---------------------------------------------------------------------
    // Operator: paying players
    // ---------------------------------------------------------------------

    /// @notice Pay `amount` GEAR from the vault to `recipient`. Operators only, and not while paused.
    /// @dev Must be within the per-call limit, today's remaining daily total, and (if switched on)
    ///      the recipient's own daily limit. The daily counters reset at 00:00 UTC.
    function dispense(address recipient, uint256 amount) external onlyOperator whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > maxDispense) revert ExceedsMaxDispense();

        // Start a fresh counter when a new UTC day has begun.
        uint256 today = block.timestamp / 1 days;
        if (today != currentDay) {
            currentDay = today;
            dispensedToday = 0;
        }

        uint256 newTotal = dispensedToday + amount;
        if (newTotal > dailyCap) revert ExceedsDailyCap();

        if (perWalletDailyCap != 0) {
            uint256 newWalletTotal = _walletDispensed[recipient][today] + amount;
            if (newWalletTotal > perWalletDailyCap) revert ExceedsWalletDailyCap();
            _walletDispensed[recipient][today] = newWalletTotal;
        }

        if (gearToken.balanceOf(address(this)) < amount) revert InsufficientVaultBalance();

        // Update counters before sending tokens.
        dispensedToday = newTotal;

        _safeTransfer(address(gearToken), recipient, amount);

        emit Dispensed(msg.sender, recipient, amount);
    }

    // ---------------------------------------------------------------------
    // Owner: operators and limits
    // ---------------------------------------------------------------------

    /// @notice Allow `operator` to call dispense().
    function authorizeOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = true;
        emit OperatorAuthorized(operator);
    }

    /// @notice Stop `operator` from calling dispense().
    function revokeOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = false;
        emit OperatorRevoked(operator);
    }

    /// @notice Change the per-call dispense limit.
    function setMaxDispense(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = maxDispense;
        maxDispense = newLimit;
        emit MaxDispenseUpdated(oldLimit, newLimit);
    }

    /// @notice Change the total daily dispense limit. Takes effect immediately for today.
    function setDailyCap(uint256 newCap) external onlyOwner {
        uint256 oldCap = dailyCap;
        dailyCap = newCap;
        emit DailyCapUpdated(oldCap, newCap);
    }

    /// @notice Change the per-wallet daily limit. Set to 0 to switch it off.
    function setPerWalletDailyCap(uint256 newCap) external onlyOwner {
        uint256 oldCap = perWalletDailyCap;
        perWalletDailyCap = newCap;
        emit PerWalletDailyCapUpdated(oldCap, newCap);
    }

    /// @notice Pause (true) or unpause (false) dispense().
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseToggled(_paused);
    }

    // ---------------------------------------------------------------------
    // Owner: moving funds out (not limited by the daily caps)
    // ---------------------------------------------------------------------

    /// @notice Take `amount` GEAR out of the vault to `to`.
    function withdrawGear(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (gearToken.balanceOf(address(this)) < amount) revert InsufficientVaultBalance();
        _safeTransfer(address(gearToken), to, amount);
        emit GearWithdrawn(to, amount);
    }

    /// @notice Recover any OTHER token that was sent here by mistake, to the address you choose.
    ///         GEAR cannot be rescued with this function; use withdrawGear instead.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(gearToken)) revert CannotRescueGear();
        _safeTransfer(token, to, amount);
        emit TokenRescued(token, amount, to);
    }

    // ---------------------------------------------------------------------
    // Two-step ownership
    // ---------------------------------------------------------------------

    /// @notice Step 1: offer ownership to `newOwner`. Nothing changes until they accept.
    ///         Calling again replaces the earlier offer.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2: the offered address calls this to become the owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /// @notice Cancel an ownership offer that has not been accepted yet.
    function cancelOwnershipTransfer() external onlyOwner {
        address cancelled = pendingOwner;
        if (cancelled == address(0)) revert NoPendingOwner();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, cancelled);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice GEAR currently held by the vault.
    function vaultBalance() external view returns (uint256) {
        return gearToken.balanceOf(address(this));
    }

    /// @notice How much more dispense() can pay out in total today (resets 00:00 UTC).
    function remainingToday() external view returns (uint256) {
        uint256 used = (block.timestamp / 1 days == currentDay) ? dispensedToday : 0;
        return used >= dailyCap ? 0 : dailyCap - used;
    }

    /// @notice How much `wallet` has received from dispense() today.
    function walletDispensedToday(address wallet) external view returns (uint256) {
        return _walletDispensed[wallet][block.timestamp / 1 days];
    }

    /// @notice How much more `wallet` can receive today. Returns type(uint256).max if the
    ///         per-wallet limit is switched off.
    function walletRemainingToday(address wallet) external view returns (uint256) {
        if (perWalletDailyCap == 0) return type(uint256).max;
        uint256 used = _walletDispensed[wallet][block.timestamp / 1 days];
        return used >= perWalletDailyCap ? 0 : perWalletDailyCap - used;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Safe transfer: works with tokens that return true and tokens that return nothing,
    ///      and fails if the token address is not a contract or the token reports failure.
    function _safeTransfer(address token, address to, uint256 amount) private {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
