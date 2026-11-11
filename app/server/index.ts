import type { ProofResult } from "@zkpassport/sdk"
import { type IncomingMessage, type ServerResponse, createServer } from "node:http"
import { type GateMode, Relayer } from "./relayer"

const PORT = Number(process.env.PORT ?? 3001)

const relayer = await Relayer.start({
  nodeUrl: process.env.AZTEC_NODE_URL ?? "https://aztec-testnet.drpc.org",
  // ZKPassport's registry on the Aztec testnet
  registryAddress:
    process.env.REGISTRY_ADDRESS ??
    "0x019de2b2c83e178733dce20707949a17ec3465caba6ccd24b3d861f151bf0f30",
  domain: process.env.APP_DOMAIN ?? "localhost",
  deploymentsPath: new URL("./deployments.json", import.meta.url).pathname,
})

createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", "http://localhost")
    if (request.method === "GET" && url.pathname === "/api/gates") {
      return send(response, 200, relayer.gateAddresses())
    }
    if (request.method === "GET" && url.pathname === "/api/badge") {
      const badge = await relayer.hasBadge(
        gateMode(url.searchParams.get("mode")),
        address(url.searchParams.get("user")),
      )
      return send(response, 200, { badge })
    }
    if (request.method === "POST" && url.pathname === "/api/claim") {
      const body = (await readJson(request)) as {
        mode?: string
        user?: string
        proof?: ProofResult
      }
      if (!body.proof) {
        return send(response, 400, { error: "missing proof" })
      }
      const txHash = await relayer.claim(
        gateMode(body.mode ?? null),
        address(body.user ?? null),
        body.proof,
      )
      return send(response, 200, { txHash })
    }
    send(response, 404, { error: "not found" })
  } catch (error) {
    console.error(error)
    send(response, 500, { error: errorMessage(error) })
  }
}).listen(PORT, () => console.log(`Fortuna relayer on http://localhost:${PORT}`))

/** A failed contract assertion's own text, without the simulation context around it. */
function errorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  return message.match(/Assertion failed: ([^'\n]+)/)?.[1]?.trim() ?? message
}

function gateMode(value: string | null): GateMode {
  if (value !== "live" && value !== "dev") {
    throw new Error(`mode must be live or dev, got ${value}`)
  }
  return value
}

function address(value: string | null): string {
  if (!value || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`not an Aztec address: ${value}`)
  }
  return value
}

function send(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "Content-Type": "application/json" })
  response.end(JSON.stringify(body))
}

async function readJson(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []
  for await (const chunk of request) {
    chunks.push(chunk as Buffer)
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf-8"))
}
