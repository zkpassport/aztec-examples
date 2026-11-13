import { AztecAddress } from "@aztec-labs/aztec.js/addresses"
import {
  Contract,
  getContractInstanceFromInstantiationParams,
} from "@aztec-labs/aztec.js/contracts"
import { Fr } from "@aztec-labs/aztec.js/fields"
import type { createAztecNodeClient } from "@aztec-labs/aztec.js/node"
import { createAztecNodeDebugClient } from "@aztec-labs/stdlib/interfaces/client"
import type { EmbeddedWallet } from "@aztec-labs/wallets/embedded"
import { registerZKPassportRegistry, ZKPassportRegistryArtifact } from "@zkpassport/aztec"
import { createRegistryClient } from "@zkpassport/registry"
import { circuitVersionToBytes32 } from "@zkpassport/utils/registry"
import { createHash } from "node:crypto"

/** The L1 chain id of a local network, whose Anvil runs on Ethereum's dev chain id */
export const LOCAL_NETWORK_L1_CHAIN_ID = 31337

// verify_zkpassport_proof looks for the registry at the address these deploy it to: they must
// match zkpassport_registry_contract::local_network_registry
const LOCAL_NETWORK_REGISTRY_SALT = Fr.fromHexString(
  `0x${createHash("sha256").update("ZKPASSPORT::AZTEC::LOCAL_NETWORK_REGISTRY").digest().subarray(0, 31).toString("hex")}`,
)
const MODE_VALID_WITHIN_WINDOW = 3
const VALIDITY_WINDOW = 86400n
// The registry's delay before a change goes live, which a local network can warp past
const REGISTRY_DELAY = 86400

const REGISTRY_CERTIFICATE = 1n
const REGISTRY_CIRCUIT = 2n
const CIRCUIT_VERSION = "0.22.0"
const WAIT = { timeout: 3600, interval: 1 } as const

/**
 * Deploy ZKPassport's registry on a local network where `verify_zkpassport_proof` finds it, unless
 * it is there already, with the network's test accounts as admin and operator. Seed it with what
 * the gates check against Sepolia, the registries dev-mode proofs use: the latest certificate root,
 * the circuit root of circuits 0.22.0 and their `outer_count_5` vk. Then warp time past the
 * registry's delay so the values are live.
 */
export async function setUpLocalNetworkRegistry(
  node: ReturnType<typeof createAztecNodeClient>,
  nodeUrl: string,
  wallet: EmbeddedWallet,
  admin: AztecAddress,
  operator: AztecAddress,
): Promise<AztecAddress> {
  const constructorArgs = [admin, operator, MODE_VALID_WITHIN_WINDOW, VALIDITY_WINDOW]
  const instance = await getContractInstanceFromInstantiationParams(ZKPassportRegistryArtifact, {
    constructorArgs,
    salt: LOCAL_NETWORK_REGISTRY_SALT,
    deployer: AztecAddress.ZERO,
  })
  const deployed = await node.getContract(instance.address)
  if (deployed) {
    await registerZKPassportRegistry(wallet, node, deployed.address)
    console.log(`Local network registry: ${instance.address}`)
    return instance.address
  }

  console.log("Deploying and seeding the local network registry from Sepolia's registries...")
  const { contract: registry } = await Contract.deploy(
    wallet,
    ZKPassportRegistryArtifact,
    constructorArgs,
    "constructor",
    {
      salt: LOCAL_NETWORK_REGISTRY_SALT,
      universalDeploy: true,
    },
  ).send({ from: admin, wait: WAIT })
  if (!registry.address.equals(instance.address)) {
    throw new Error(`the registry landed at ${registry.address}, not ${instance.address}`)
  }

  const sepolia = createRegistryClient("ethereum_sepolia")
  const certificateRoot = await sepolia.getCertificateRootDetails()
  const manifest = await sepolia.getCircuitManifest(undefined, { version: CIRCUIT_VERSION })
  const vkHash = manifest.circuits["outer_count_5"]?.hash
  if (!vkHash) {
    throw new Error(`circuits ${CIRCUIT_VERSION} have no outer_count_5`)
  }
  const version = Fr.fromHexString(circuitVersionToBytes32(CIRCUIT_VERSION))
  // Valid from a day ago, so proofs made from now on fall inside it
  const circuitRootValidFrom = BigInt(Math.floor(Date.now() / 1000) - 86400)

  await registry.methods
    .update_root(
      REGISTRY_CERTIFICATE,
      Fr.fromHexString(certificateRoot.root),
      0n,
      BigInt(Math.floor(certificateRoot.validFrom.getTime() / 1000)),
    )
    .send({ from: operator, wait: WAIT })
  await registry.methods
    .update_root(REGISTRY_CIRCUIT, Fr.fromHexString(manifest.root), 0n, circuitRootValidFrom)
    .send({ from: operator, wait: WAIT })
  await registry.methods
    .add_accepted_vk(version, Fr.fromHexString(vkHash))
    .send({ from: admin, wait: WAIT })
  await registry.methods.set_version_status(version, true).send({ from: admin, wait: WAIT })

  await createAztecNodeDebugClient(nodeUrl).warpL2TimeAtLeastBy(REGISTRY_DELAY + 120)
  const { result: accepted } = await registry.methods
    .is_vk_accepted(version, Fr.fromHexString(vkHash))
    .simulate({ from: admin })
  if (!accepted) {
    throw new Error("the seeded vk is not live after the warp")
  }

  console.log(
    `Local network registry: ${registry.address}, certificate root ${certificateRoot.root}`,
  )
  return registry.address
}
