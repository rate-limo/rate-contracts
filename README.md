<div align="center">

<img src="./media/iter_profile.png" width=100/>

  <h1><code>Iter</code></h1>

  <p>
    <strong>A monorepo of Iter contracts</strong>
  </p>
</div>

## What is Iter?

Iter is a protocol to make next-gen DeFi to solve four problems in Crypto's transparency:

**`Transparency`**: Iter's onchain CLOB provides listing mechanism where we do fair auctions to list assets officially or permissionlessly with fixed cost for making a pair.

**`Insolvency`**: All operations in Iter's CLOB are done in self-custody.

**`Security`**: By having segregation of user's funds into each account with CLOB, hackers cannot hack Iter unless they hack all of user's wallet.

**`Personalization`**: By having each users' activity recorded in blockchain, personalized incentivization is possible such as fee discount, more points to top active traders in Iter orderbook exchange.

## The Iter Super App: Your DeFi 3.0 Gateway

From the lessons of DeFi 2.0, Iter focuses on self-sovereignty of users asset and personalized experience. Iter declares itself as the gateway of DeFi 3.0, learning from DeFi 2.0's negative consequences.

DeFi 2.0's failure to ensure user's safety while co-mingling assets in one contract caused losses over more than 1 billion USD worth of wealth by end users. To put this easily, it is like one goes to a bank with an account shared by all customers. Insiders or hackers were able to extract the whole users' fund due to this missing concept of self-custody within DeFi 2.0 smart contracts. Cases would include a famous quote 'Steady lads, deploying capital' by Do Kwon, a Luna Foundation Guard council. Whether he was guilty or not, the management of each positions for UST/LUNA had to be authorized only to each users who minted UST.

DeFi 2.0 also made a imbalanced social hierarchy, where regular users who are active using the app or protocol was ignored by few who had asymmetric shares in the community. While the community is formed with different individuals with different situations, DeFi 2.0 projects or chains have always been making Totalitarian propaganda based on materialistic values, emphasizing buying more of their coins or tokens just for ascending in its social hierarchy, depositing tokens to AMM pairs to increase TVL, often asking projects to grow TVL exclusively on one chain, or boost yield by leveraging endlessly. However, people always urged crypto to see apps which can have their own experience for mass adoption.

DeFi 3.0 proposed by Iter focuses more on users' growth and experience than TVL for the whole crypto community. To remove consideration for TVL, Iter builds fully onchain CLOB first, focusing on better experience and capital efficiency. Other money legos always has segregation of users' fund into its protocol so that users can have safer experience than DeFi 2.0 by default. Iter makes community to willingly buy $ITER token and use it for better experience instead of having higher social hierarchy in the community. The Iter team is building new money legos that will deliver real, personalized user experiences.

## Money Legos

Each money lego has README to build, test, and deploy with LICENSE.

- **[`point`](src/point/)** (governance & incentive management)
- **[`exchange`](src/exchange/)** (fully onchain CLOB)
- **[`stablecoin`](src/stablecoin/)** (CDP stablecoin with delta-neutral strategy)
- **[`futures`](src/futures/)** (fully onchain futures)

## Getting Started

First, clone the repository
```
https://github.com/iter-cx/iter-contracts.git
```
Then, check each money lego directory's README for further development guidance.

## Docs

Each money lego's README covers its own concepts, build and deploy steps; [`src/deploy.md`](src/deploy.md) covers deployment across the monorepo. The app lives at [iter.cx](https://iter.cx).

## Security

### Unit Tests

[Contract Test Directory](./test)

### Audits

[Hacken in 2023](./audits/hacken-2023)
[Defimoon in 2023](./audits/defimoon-2023)

## Disclaimer

_These smart contracts and code are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of the user interface or the smart contracts and code. There can be no assurance they will work as intended, and users may experience delays, failures, errors, omissions or loss of transmitted information. In addition, using these smart contracts and code should be conducted in accordance with applicable law. Nothing in this repo should be construed as investment advice or legal advice for any particular facts or circumstances and is not meant to replace competent counsel. It is strongly advised for you to contact a reputable attorney in your jurisdiction for any questions or concerns with respect thereto. Iter is not liable for any use of the foregoing and users should proceed with caution and use at their own risk._

## License

This software code is licensed with [BSL-1.1](./LICENSE).

Terms of some parts of the code in the monorepo have different terms.
