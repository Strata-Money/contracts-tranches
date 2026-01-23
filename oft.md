## Layerzero deployment stuff

### OFT deployment and testing

```bash
# Deploy on Base Sepolia
forge script script/CombinedDeploy.s.sol:CombinedDeploy \
  --sig "deployOnBase()" \
  --rpc-url base_sepolia \
  --broadcast \
  --private-key $PK

# Deploy on Arbitrum Sepolia
forge script script/CombinedDeploy.s.sol:CombinedDeploy \
  --sig "deployOnArbitrum()" \
  --rpc-url arbitrum_sepolia \
  --broadcast \
  --private-key $PK

# Setup Base Sepolia
forge script script/CombinedDeploy.s.sol:CombinedDeploy \
  --sig "setupBase()" \
  --rpc-url base_sepolia \
  --broadcast \
  --private-key $PK

# Setup Arbitrum Sepolia
OFT_ADDRESS=0x8942FD5DDe1d68DcB9985537CeF1bC435a423c2F \
BASE_PEER=0x0b40544bd97da9Dfd97B69Ab08705C2473dE2560 \
forge script script/CombinedDeploy.s.sol:CombinedDeploy \
  --sig "setupArbitrum()" \
  --rpc-url arbitrum_sepolia \
  --broadcast \
  --private-key $PK

# Send tokens from Base to Arbitrum
OFT_ADDRESS="0x0b40544bd97da9Dfd97B69Ab08705C2473dE2560" \
TOKENS_TO_SEND="10000000000000000000" \
TO_ADDRESS="0xd4bBBab281e64Ad7A81A49Ac3741Ba13749A8929" \
forge script script/CombinedDeploy.s.sol:CombinedDeploy \
  --sig "sendFromBase()" \
  --rpc-url base_sepolia \
  --broadcast \
  --private-key $PK
```

Example tx of sending tokens from base to arbitrum (testnets):
https://testnet.layerzeroscan.com/tx/0xcc96bb0a03b44a25638514f89f060fb98306979d06fdce33484c63912eeb4995
