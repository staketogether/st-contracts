import '@nomicfoundation/hardhat-toolbox'
import { HardhatUserConfig } from 'hardhat/config'

import dotenv from 'dotenv'
import { checkVariables } from './test/utils/env'
dotenv.config()

checkVariables()

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.18',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  typechain: {
    outDir: 'typechain',
    target: 'ethers-v6'
  },
  networks: {
    goerli: {
      url: `https://eth-goerli.g.alchemy.com/v2/${process.env.ALCHEMY_GOERLI_API_KEY}`,
      accounts: [process.env.DEPLOYER_PRIVATE_KEY as string]
    },
    localhost: {
      url: 'http://127.0.0.1:8545'
    },
    hardhat: {
      // forking: {
      //   url: `https://eth-goerli.g.alchemy.com/v2/${process.env.ALCHEMY_GOERLI_API_KEY}`
      // },
      accounts: [
        {
          privateKey: process.env.ACCOUNT_1_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_2_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_3_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_4_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_5_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_6_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_7_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_8_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_9_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        },
        {
          privateKey: process.env.ACCOUNT_10_PRIVATE_KEY as string,
          balance: '10000000000000000000000'
        }
      ]
    }
  },

  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY as string
  }
}

export default config
