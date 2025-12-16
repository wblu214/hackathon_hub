const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();

    console.log("正在使用账户部署合约:", deployer.address);

    // 获取合约工厂
    const HackathonHub = await hre.ethers.getContractFactory("HackathonHub");

    // 部署合约，传入部署者地址作为初始 Owner
    const hackathonHub = await HackathonHub.deploy(deployer.address);

    // 等待部署完成
    await hackathonHub.waitForDeployment();

    const address = await hackathonHub.getAddress();
    console.log("HackathonHub 已部署到:", address);
    console.log(`验证合约命令: npx hardhat verify --network zeta_testnet ${address} ${deployer.address}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});