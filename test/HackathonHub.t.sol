// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HackathonHub.sol";

contract HackathonHubTest is Test {
    HackathonHub hub;

    address platformOwner = address(0xA11CE);
    uint256 listingFee = 0.0035 ether;
    uint256 likeStakeAmount = 0.001 ether;
    uint256 platformFeeBps = 500; // 5%

    function setUp() public {
        hub = new HackathonHub(
            platformOwner,
            listingFee,
            likeStakeAmount,
            platformFeeBps
        );
    }

    function testCreateHackathonAndProjectLikeTipFlow() public {
        // 0. 官方 Hackathon 创建（B 端付费）
        address organizer = address(0xABCD);
        vm.deal(organizer, 1 ether);

        uint256 officialFee = hub.officialHackathonCreationFee();

        vm.prank(organizer);
        uint256 hackathonId = hub.createHackathon{value: officialFee}(
            "Official Hackathon",
            "ipfs://hackathon",
            true
        );

        HackathonHub.Hackathon memory h = hub.getHackathon(hackathonId);
        assertTrue(h.exists);
        assertTrue(h.isOfficial);
        assertEq(h.id, hackathonId);

        // 1. 上架项目并挂到该 Hackathon，检查挂组折扣是否生效
        address projectOwner = address(0xB0B);
        vm.deal(projectOwner, 1 ether);

        uint256 beforeBalance = projectOwner.balance;

        vm.prank(projectOwner);
        uint256 projectId = hub.createProject{value: listingFee}(
            "Test Project",
            "Description",
            "ipfs://metadata",
            hackathonId
        );

        uint256 refundBps = hub.groupedListingRefundBps();
        uint256 expectedRefund = (listingFee * refundBps) / 10_000;
        uint256 expectedPaid = listingFee - expectedRefund;
        uint256 afterBalance = projectOwner.balance;

        assertEq(afterBalance, beforeBalance - expectedPaid);

        // 2. Like the project (Stake-to-Like)
        address liker = address(0xC0DE);
        vm.deal(liker, 1 ether);

        vm.prank(liker);
        hub.likeProject{value: likeStakeAmount}(projectId);

        // 3. Tip the project
        address tipper = address(0xD00D);
        vm.deal(tipper, 1 ether);

        uint256 tipAmount = 0.1 ether;
        vm.prank(tipper);
        hub.tipProject{value: tipAmount}(projectId);

        HackathonHub.Project memory p = hub.getProject(projectId);

        assertEq(p.id, projectId);
        assertEq(p.owner, projectOwner);
        assertEq(p.totalStake, likeStakeAmount);
        assertEq(p.totalTips, tipAmount);
        assertEq(p.likeCount, 1);
        assertTrue(p.exists);
    }
}
