// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HackathonHub - Omnichain developer project registry and incentive hub
/// @notice Simplified single-chain MVP that can be deployed on ZetaChain EVM testnet.
contract HackathonHub {
    // ------------------------------------------------------------
    // Data structures
    // ------------------------------------------------------------

    struct UserProfile {
        string username; // display name used by the frontend
        string avatar; // avatar URL or content hash (e.g. IPFS)
        bool exists;
    }

    struct Project {
        uint256 id;
        address owner; // project owner / developer team
        string title;
        string description;
        string metadataURI; // extra metadata (e.g. JSON / IPFS)
        uint256 createdAt;
        uint256 totalStake; // total staked amount from likes
        uint256 totalTips; // total tips (before split) sent to this project
        uint256 likeCount; // number of like actions (for basic ranking)
        uint256 hackathonId; // optional hackathon group id (0 = none)
        bool exists;
    }

    struct LikeInfo {
        address user;
        uint256 amount;
        uint256 timestamp;
    }

    struct TipInfo {
        address user;
        uint256 amount;
        uint256 timestamp;
    }

    struct Hackathon {
        uint256 id;
        address owner; // organizer
        string name;
        string metadataURI; // description, logo, prize info etc.
        bool isOfficial; // true = 官方 hackathon, false = 社区 / 普通组
        uint256 createdAt;
        bool exists;
    }

    // ------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------

    address public owner; // platform owner

    // Economic parameters (can be tuned per deployment)
    uint256 public listingFee; // project listing fee ("项目发布费", e.g. 3.5 U in native units)
    uint256 public likeStakeAmount; // minimum stake for a "like"
    uint256 public platformFeeBps; // platform fee for tips, in basis points (500 = 5%)
    uint256 public groupedListingRefundBps; // 挂组折扣返还比例, 3000 = 30% 原价返还
    uint256 public officialHackathonCreationFee; // 官方 Hackathon 组建费（e.g. 35 U）
    uint256 public communityHackathonCreationFee; // 社区 Hackathon 组建费（可以为 0）

    uint256 public platformBalance; // accumulated platform fees (listing + platform cut from tips)

    uint256 public nextProjectId = 1;
    uint256 public nextHackathonId = 1;

    mapping(address => UserProfile) private profiles;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => LikeInfo[]) private projectLikes;
    mapping(uint256 => TipInfo[]) private projectTips;
    mapping(uint256 => Hackathon) public hackathons;

    // Simple reentrancy guard
    uint256 private locked = 1;

    // ------------------------------------------------------------
    // Errors (prefer revert over require for clearer error types)
    // ------------------------------------------------------------

    error NotOwner();
    error InvalidOwner();
    error InvalidPlatformFeeBps();
    error ProjectNotFound();
    error HackathonNotFound();
    error InsufficientListingFee(uint256 required, uint256 provided);
    error InsufficientHackathonCreationFee(uint256 required, uint256 provided);
    error InsufficientStake(uint256 required, uint256 provided);
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientPlatformBalance(uint256 requested, uint256 available);
    error TransferFailed();
    error Reentrancy();

    // ------------------------------------------------------------
    // Events
    // ------------------------------------------------------------

    event ProfileUpdated(address indexed user, string username, string avatar);

    event ProjectCreated(
        uint256 indexed projectId,
        address indexed owner,
        uint256 hackathonId
    );

    event ProjectLiked(
        uint256 indexed projectId,
        address indexed user,
        uint256 amount
    );

    event ProjectTipped(
        uint256 indexed projectId,
        address indexed user,
        uint256 amount,
        uint256 devAmount,
        uint256 platformAmount
    );

    event HackathonCreated(
        uint256 indexed hackathonId,
        address indexed owner,
        bool isOfficial,
        string name,
        string metadataURI,
        uint256 feePaid
    );

    event ProjectJoinedHackathon(
        uint256 indexed projectId,
        uint256 indexed hackathonId
    );

    event PlatformWithdrawn(address indexed to, uint256 amount);

    // ------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------

    /// @param _owner platform owner address, receives platform withdrawals
    /// @param _listingFee project listing fee (in native token, e.g. ZETA)
    /// @param _likeStakeAmount minimum stake for each like
    /// @param _platformFeeBps tip fee in basis points (500 = 5%)
    constructor(
        address _owner,
        uint256 _listingFee,
        uint256 _likeStakeAmount,
        uint256 _platformFeeBps
    ) {
        if (_owner == address(0)) revert InvalidOwner();
        if (_platformFeeBps > 10_000) revert InvalidPlatformFeeBps();

        owner = _owner;
        listingFee = _listingFee;
        likeStakeAmount = _likeStakeAmount;
        platformFeeBps = _platformFeeBps;

        // 默认经济模型参数：可后续根据需要扩展 setter 调整
        // 30% 挂组返还：挂官方/社区 Hackathon 组时，原 listingFee 的 30% 返还给项目方
        groupedListingRefundBps = 3_000;
        // 官方 Hackathon 组建费：约等于 "35 U"（如果 listingFee = 3.5 U，则 *10）
        officialHackathonCreationFee = _listingFee * 10;
        // 社区 Hackathon 组建费：默认 0，可以之后在新版本里做成可配置
        communityHackathonCreationFee = 0;
    }

    // ------------------------------------------------------------
    // User profile (for avatar / username display)
    // ------------------------------------------------------------

    function setProfile(
        string calldata username,
        string calldata avatar
    ) external {
        profiles[msg.sender] = UserProfile({
            username: username,
            avatar: avatar,
            exists: true
        });

        emit ProfileUpdated(msg.sender, username, avatar);
    }

    function getProfile(
        address user
    ) external view returns (UserProfile memory) {
        return profiles[user];
    }

    // ------------------------------------------------------------
    // Hackathon / 组管理
    // ------------------------------------------------------------

    function _getHackathon(
        uint256 hackathonId
    ) internal view returns (Hackathon storage h) {
        h = hackathons[hackathonId];
        if (!h.exists) revert HackathonNotFound();
    }

    /// @notice Read a hackathon struct for off-chain consumers.
    function getHackathon(
        uint256 hackathonId
    ) external view returns (Hackathon memory) {
        Hackathon storage h = _getHackathon(hackathonId);
        return h;
    }

    /// @notice 创建 Hackathon 组（官方 / 社区），用于项目挂组。
    /// @dev 官方组需要支付 officialHackathonCreationFee，社区组支付 communityHackathonCreationFee。
    function createHackathon(
        string calldata name,
        string calldata metadataURI,
        bool isOfficial
    ) external payable nonReentrant returns (uint256 hackathonId) {
        uint256 requiredFee = isOfficial
            ? officialHackathonCreationFee
            : communityHackathonCreationFee;

        if (msg.value < requiredFee) {
            revert InsufficientHackathonCreationFee({
                required: requiredFee,
                provided: msg.value
            });
        }

        // 协议收入：官方/社区组建费全部进入平台余额
        platformBalance += requiredFee;

        // 退还多余的 gas token（避免用户多转）
        uint256 refund = msg.value - requiredFee;
        if (refund > 0) {
            (bool okRefund, ) = msg.sender.call{value: refund}("");
            if (!okRefund) revert TransferFailed();
        }

        hackathonId = nextHackathonId;
        nextHackathonId = hackathonId + 1;

        hackathons[hackathonId] = Hackathon({
            id: hackathonId,
            owner: msg.sender,
            name: name,
            metadataURI: metadataURI,
            isOfficial: isOfficial,
            createdAt: block.timestamp,
            exists: true
        });

        emit HackathonCreated(
            hackathonId,
            msg.sender,
            isOfficial,
            name,
            metadataURI,
            requiredFee
        );
    }

    // ------------------------------------------------------------
    // Project lifecycle
    // ------------------------------------------------------------

    /// @notice 上架项目（不挂任何 Hackathon 组）。前端可直接使用 createProject 填 hackathonId=0。
    function listProject(
        string calldata title,
        string calldata description,
        string calldata metadataURI
    ) external payable returns (uint256 projectId) {
        // wrapper 保留给早期脚本使用，实际逻辑由 _createProject 执行
        projectId = _createProject(title, description, metadataURI, 0);
    }

    /// @notice 上架项目，并可选择挂到某个 Hackathon 组（实现“挂组折扣”）。
    /// @dev 如果 hackathonId != 0 且组存在，则按 groupedListingRefundBps 返还部分 listingFee。
    function createProject(
        string calldata title,
        string calldata description,
        string calldata metadataURI,
        uint256 hackathonId
    ) external payable returns (uint256 projectId) {
        projectId = _createProject(title, description, metadataURI, hackathonId);
    }

    function _createProject(
        string calldata title,
        string calldata description,
        string calldata metadataURI,
        uint256 hackathonId
    ) internal nonReentrant returns (uint256 projectId) {
        if (msg.value < listingFee) {
            revert InsufficientListingFee({
                required: listingFee,
                provided: msg.value
            });
        }

        uint256 feeToPlatform = listingFee;
        uint256 refundForGrouping = 0;

        if (hackathonId != 0) {
            // 确认 Hackathon 存在（官方或社区均可获得折扣）
            _getHackathon(hackathonId);

            // 原 listingFee 的 groupedListingRefundBps 返还给项目方
            refundForGrouping =
                (listingFee * groupedListingRefundBps) /
                10_000;
            feeToPlatform = listingFee - refundForGrouping;
        }

        // 平台收入：扣除挂组返还后的实际部分
        platformBalance += feeToPlatform;

        // 退多余的 gas token + 挂组返还
        uint256 extra = msg.value - listingFee;
        uint256 totalRefund = extra + refundForGrouping;
        if (totalRefund > 0) {
            (bool okRefund, ) = msg.sender.call{value: totalRefund}("");
            if (!okRefund) revert TransferFailed();
        }

        projectId = nextProjectId;
        nextProjectId = projectId + 1;

        projects[projectId] = Project({
            id: projectId,
            owner: msg.sender,
            title: title,
            description: description,
            metadataURI: metadataURI,
            createdAt: block.timestamp,
            totalStake: 0,
            totalTips: 0,
            likeCount: 0,
            hackathonId: hackathonId,
            exists: true
        });

        emit ProjectCreated(
            projectId,
            msg.sender,
            hackathonId
        );

        if (hackathonId != 0) {
            emit ProjectJoinedHackathon(projectId, hackathonId);
        }
    }

    function _getProject(
        uint256 projectId
    ) internal view returns (Project storage p) {
        p = projects[projectId];
        if (!p.exists) revert ProjectNotFound();
    }

    /// @notice Read a project struct for off-chain consumers.
    function getProject(
        uint256 projectId
    ) external view returns (Project memory) {
        Project storage p = _getProject(projectId);
        return p;
    }

    /// @notice 前端获取当前项目数量，用于 off-chain 遍历 projectId 从 1..N。
    function getProjectCount() external view returns (uint256) {
        return nextProjectId - 1;
    }

    /// @notice 前端获取当前 Hackathon 数量，用于 off-chain 遍历 hackathonId 从 1..N。
    function getHackathonCount() external view returns (uint256) {
        return nextHackathonId - 1;
    }

    // ------------------------------------------------------------
    // Stake-to-like
    // ------------------------------------------------------------

    /// @notice Like a project by staking native tokens.
    /// @dev Amount is added to project.totalStake and kept in the contract.
    function likeProject(
        uint256 projectId
    ) external payable nonReentrant {
        Project storage p = _getProject(projectId);

        if (msg.value < likeStakeAmount) {
            revert InsufficientStake({
                required: likeStakeAmount,
                provided: msg.value
            });
        }

        p.totalStake += msg.value;
        p.likeCount += 1;

        projectLikes[projectId].push(
            LikeInfo({
                user: msg.sender,
                amount: msg.value,
                timestamp: block.timestamp
            })
        );

        emit ProjectLiked(projectId, msg.sender, msg.value);
    }

    function getLikes(
        uint256 projectId
    ) external view returns (LikeInfo[] memory) {
        Project storage p = _getProject(projectId);
        // silence unused-variable warning while still validating existence
        p;
        return projectLikes[projectId];
    }

    // ------------------------------------------------------------
    // Tips with 95% / 5% split
    // ------------------------------------------------------------

    /// @notice Tip a project. 95% goes to the project owner, 5% (configurable via platformFeeBps) to the platform.
    function tipProject(
        uint256 projectId
    ) external payable nonReentrant {
        Project storage p = _getProject(projectId);

        if (msg.value == 0) revert ZeroAmount();

        p.totalTips += msg.value;

        uint256 platformAmount = (msg.value * platformFeeBps) / 10_000;
        uint256 devAmount = msg.value - platformAmount;

        platformBalance += platformAmount;

        projectTips[projectId].push(
            TipInfo({
                user: msg.sender,
                amount: msg.value,
                timestamp: block.timestamp
            })
        );

        // Send developer share directly to project owner
        (bool ok, ) = p.owner.call{value: devAmount}("");
        if (!ok) revert TransferFailed();

        emit ProjectTipped(
            projectId,
            msg.sender,
            msg.value,
            devAmount,
            platformAmount
        );
    }

    function getTips(
        uint256 projectId
    ) external view returns (TipInfo[] memory) {
        Project storage p = _getProject(projectId);
        // silence unused-variable warning while still validating existence
        p;
        return projectTips[projectId];
    }

    // ------------------------------------------------------------
    // Platform withdrawals
    // ------------------------------------------------------------

    /// @notice Withdraw accumulated platform fees (listing + platform cut from tips).
    /// @dev Only callable by the owner (platform).
    function withdrawPlatform(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > platformBalance) {
            revert InsufficientPlatformBalance({
                requested: amount,
                available: platformBalance
            });
        }

        platformBalance -= amount;

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit PlatformWithdrawn(to, amount);
    }
}
