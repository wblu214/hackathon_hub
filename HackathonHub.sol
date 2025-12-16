// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ZetaChain ZRC-20 接口，用于处理跨链提现
interface IZRC20 {
    function withdraw(bytes memory to, uint256 amount) external returns (bool);
}

/**
 * @title HackathonHub
 * @dev Omnichain Developer Incentive Protocol on ZetaChain.
 *      Handles project registry, stake-to-like, and tipping logic.
 */
contract HackathonHub is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error InvalidFeeAmount();
    error InvalidTipAmount();
    error ProjectDoesNotExist();
    error NotOfficialGroup();
    error TokenNotWhitelisted();
    error TransferFailed();
    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();

    // --- Structs ---
    struct UserProfile {
        string username;
        string avatarURI;
        bool isRegistered;
    }

    struct Project {
        uint256 id;
        address author;
        string metadataURI; // IPFS hash or URL to project details
        uint256 totalLikes;
        uint256 totalTipsCount;
        bool isOfficialGroup;
        uint256 associatedGroupId; // 0 if none
        uint256 createdAt;
    }

    struct TipInfo {
        address user;
        address token;
        uint256 amount;
        string message;
        uint256 timestamp;
    }

    struct LikeInfo {
        address user;
        uint256 amount; // Staked amount
        uint256 timestamp;
    }

    // --- State Variables ---
    uint256 public nextProjectId;

    // Fees (assuming 18 decimals, e.g., ZRC-20 USDT/USDC)
    uint256 public listingFee = 35 * 10 ** 17; // 3.5 * 10^18
    uint256 public groupCreationFee = 35 * 10 ** 18;
    uint256 public likeStakeAmount = 1 * 10 ** 18;

    // Platform revenue share: 5% (500 bps)
    uint256 public constant PLATFORM_FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Whitelisted tokens for fees (e.g. ZRC-20 Stablecoins)
    mapping(address => bool) public whitelistedTokens;

    // Data Storage
    mapping(uint256 => Project) public projects;
    mapping(address => UserProfile) public userProfiles;

    // History (for frontend display)
    mapping(uint256 => TipInfo[]) public projectTips;
    mapping(uint256 => LikeInfo[]) public projectLikes;

    // User stakes for likes (user => amount staked)
    mapping(address => uint256) public userTotalStaked;

    // --- Events ---
    event ProjectRegistered(
        uint256 indexed projectId,
        address indexed author,
        bool isOfficialGroup,
        uint256 associatedGroupId
    );
    event ProjectLiked(
        uint256 indexed projectId,
        address indexed user,
        uint256 stakeAmount
    );
    event ProjectTipped(
        uint256 indexed projectId,
        address indexed user,
        address token,
        uint256 amount,
        string message
    );
    event UserProfileUpdated(
        address indexed user,
        string username,
        string avatarURI
    );
    event FeesWithdrawn(address indexed token, uint256 amount, address to);
    event TokenWhitelistUpdated(address token, bool status);

    constructor(address initialOwner) Ownable(initialOwner) {
        nextProjectId = 1;
    }

    // --- Modifiers ---
    modifier onlyWhitelisted(address token) {
        if (!whitelistedTokens[token]) revert TokenNotWhitelisted();
        _;
    }

    // --- Admin Functions ---
    function setListingFee(uint256 _fee) external onlyOwner {
        listingFee = _fee;
    }

    function setGroupCreationFee(uint256 _fee) external onlyOwner {
        groupCreationFee = _fee;
    }

    function setLikeStakeAmount(uint256 _amount) external onlyOwner {
        likeStakeAmount = _amount;
    }

    function setTokenWhitelist(address token, bool status) external onlyOwner {
        whitelistedTokens[token] = status;
        emit TokenWhitelistUpdated(token, status);
    }

    /// @notice Withdraw accumulated fees or staked funds (if needed for migration)
    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(token, amount, to);
    }

    /// @notice [ZetaChain 特性] 将收取的费用直接提取回原生链 (例如 ZRC-20 BTC -> Bitcoin BTC)
    /// @param token ZRC-20 代币地址
    /// @param recipient 原生链上的接收地址 (bytes 格式)
    /// @param amount 提取金额
    function withdrawFeesToNative(
        address token,
        bytes memory recipient,
        uint256 amount
    ) external onlyOwner {
        if (amount == 0) revert ZeroValue();
        // 调用 ZRC-20 的 withdraw 函数，这会销毁 ZRC-20 并触发原生链上的转账
        // 注意：跨链 Gas 费通常会从 amount 中扣除
        IZRC20(token).withdraw(recipient, amount);
        emit FeesWithdrawn(token, amount, address(0)); // address(0) 代表提取到了原生链外部地址
    }

    // --- User Profile ---
    function updateProfile(
        string calldata _username,
        string calldata _avatarURI
    ) external {
        userProfiles[msg.sender] = UserProfile({
            username: _username,
            avatarURI: _avatarURI,
            isRegistered: true
        });
        emit UserProfileUpdated(msg.sender, _username, _avatarURI);
    }

    // --- Core Logic ---

    /// @notice Register a project or create an official group
    /// @param _associatedGroupId ID of the group to join. If 0, individual listing.
    function registerProject(
        string calldata _metadataURI,
        bool _createOfficialGroup,
        uint256 _associatedGroupId,
        address _paymentToken
    ) external nonReentrant onlyWhitelisted(_paymentToken) {
        uint256 fee;

        if (_createOfficialGroup) {
            fee = groupCreationFee; // 35 U
        } else if (_associatedGroupId > 0) {
            // Validate Group
            if (projects[_associatedGroupId].author == address(0))
                revert ProjectDoesNotExist();
            if (!projects[_associatedGroupId].isOfficialGroup)
                revert NotOfficialGroup();

            // 30% Discount: 3.5 * 0.7 = 2.45 U
            fee = (listingFee * 70) / 100;
        } else {
            fee = listingFee; // 3.5 U
        }

        // Transfer fee to protocol
        IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), fee);

        uint256 projectId = nextProjectId++;
        projects[projectId] = Project({
            id: projectId,
            author: msg.sender,
            metadataURI: _metadataURI,
            totalLikes: 0,
            totalTipsCount: 0,
            isOfficialGroup: _createOfficialGroup,
            associatedGroupId: _associatedGroupId,
            createdAt: block.timestamp
        });

        emit ProjectRegistered(
            projectId,
            msg.sender,
            _createOfficialGroup,
            _associatedGroupId
        );
    }

    /// @notice Stake tokens to like a project (Sybil Resistance)
    function likeProject(
        uint256 _projectId,
        address _paymentToken
    ) external nonReentrant onlyWhitelisted(_paymentToken) {
        if (projects[_projectId].author == address(0))
            revert ProjectDoesNotExist();

        // Transfer stake to contract (locked)
        IERC20(_paymentToken).safeTransferFrom(
            msg.sender,
            address(this),
            likeStakeAmount
        );

        projects[_projectId].totalLikes += 1;
        userTotalStaked[msg.sender] += likeStakeAmount;

        projectLikes[_projectId].push(
            LikeInfo({
                user: msg.sender,
                amount: likeStakeAmount,
                timestamp: block.timestamp
            })
        );

        emit ProjectLiked(_projectId, msg.sender, likeStakeAmount);
    }

    /// @notice Tip a project developer
    function tipProject(
        uint256 _projectId,
        uint256 _amount,
        address _paymentToken,
        string calldata _message
    ) external nonReentrant onlyWhitelisted(_paymentToken) {
        Project memory proj = projects[_projectId];
        if (proj.author == address(0)) revert ProjectDoesNotExist();
        if (_amount == 0) revert ZeroValue();

        // Calculate split
        uint256 platformShare = (_amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 authorShare = _amount - platformShare;

        // 1. Platform share stays in contract
        IERC20(_paymentToken).safeTransferFrom(
            msg.sender,
            address(this),
            platformShare
        );

        // 2. Author share sent directly to developer
        IERC20(_paymentToken).safeTransferFrom(
            msg.sender,
            proj.author,
            authorShare
        );

        projects[_projectId].totalTipsCount += 1;

        projectTips[_projectId].push(
            TipInfo({
                user: msg.sender,
                token: _paymentToken,
                amount: _amount,
                message: _message,
                timestamp: block.timestamp
            })
        );

        emit ProjectTipped(
            _projectId,
            msg.sender,
            _paymentToken,
            _amount,
            _message
        );
    }

    // --- View Functions ---
    function getProjectTips(
        uint256 _projectId
    ) external view returns (TipInfo[] memory) {
        return projectTips[_projectId];
    }

    function getProjectLikes(
        uint256 _projectId
    ) external view returns (LikeInfo[] memory) {
        return projectLikes[_projectId];
    }
}
