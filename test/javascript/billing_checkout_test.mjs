import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import vm from "node:vm"

const source = await readFile(new URL("../../src/rapid_rails_template/billing/app/assets/javascripts/billing/checkout_controller.js", import.meta.url), "utf8")
const context = vm.createContext({ console, window: {}, document: { querySelector: () => ({ content: "csrf" }) } })
const module = new vm.SourceTextModule(source, { context })
await module.link(async (name) => {
  const dependency = new vm.SyntheticModule(name === "@hotwired/stimulus" ? ["Controller"] : [], function () {
    if (name === "@hotwired/stimulus") this.setExport("Controller", class {})
  }, { context })
  return dependency
})
await module.evaluate()
const Checkout = module.namespace.default
const controller = new Checkout()
const targets = ["chain", "prepare", "authorize", "review", "terms", "message", "contractLink"]
for (const name of targets) controller[`${name}Target`] = { disabled: false, hidden: false, textContent: "", focus() {} }
controller.chainTarget.value = "8453"
controller.labelsValue = { wrongWallet: "wrong-wallet", wrongChain: "wrong-chain", failed: "failed", review: "review", connecting: "connecting", signing: "signing" }
controller.appNameValue = "Test"
controller.planIdValue = 7
controller.createUrlValue = "/account/billing/subscriptions"
const terms = { domain: { chainId: 8453 }, message: { account: "0x4444444444444444444444444444444444444444", allowance: "10000001", period: "2592000", spender: "server-spender", token: "server-token" } }
const contract = { typed_data: terms, review: "Server terms", authorize_path: "/account/billing/subscriptions/9/authorize", subscription_path: "/account/billing/subscriptions/9" }
const calls = []
context.window.createBaseAccountSDK = () => ({ getProvider: () => ({ request: async (request) => {
  calls.push(request)
  if (request.method === "eth_requestAccounts") return [terms.message.account]
  if (request.method === "eth_chainId") return "0x2105"
  if (request.method === "eth_signTypedData_v4") return "0xabcd"
  return null
} }) })
let requests = []
controller.post = async (path, body) => { requests.push({ path, body }); return contract }
await controller.prepare({ preventDefault() {} })
assert.equal(requests.length, 1)
assert.equal(requests[0].body.subscription.plan_id, 7)
assert.equal(controller.termsTarget.textContent, "Server terms")
assert.equal(controller.reviewTarget.hidden, false)
assert.equal(controller.chainTarget.disabled, true)
assert.equal(calls.filter((call) => call.method === "eth_signTypedData_v4").length, 0, "review must precede signature")
context.window.location = { assign(path) { assert.equal(path, contract.subscription_path) } }
await controller.authorize({ preventDefault() {} })
const signingCall = calls.find((call) => call.method === "eth_signTypedData_v4")
assert.equal(signingCall.params[1], JSON.stringify(terms), "server terms must be signed unchanged")
assert.equal(JSON.stringify(requests[1].body), '{"signature":"0xabcd"}')
assert.equal(requests[1].path, contract.authorize_path)
controller.sdk = { getProvider: () => ({ request: async () => ["0x9999999999999999999999999999999999999999"] }) }
requests = []
await controller.authorize({ preventDefault() {} })
assert.equal(controller.messageTarget.textContent, "wrong-wallet")
assert.equal(requests.length, 0)
assert.equal(controller.authorizeTarget.disabled, false)
const resumed = new Checkout()
for (const name of targets) resumed[`${name}Target`] = { disabled: false, hidden: true }
resumed.hasContractValue = true
resumed.contractValue = contract
resumed.connect()
assert.equal(resumed.contract, contract)
assert.equal(resumed.reviewTarget.hidden, false)
assert.equal(resumed.contractLinkTarget.href, contract.subscription_path)
console.log("Billing checkout: review, immutable terms, wallet mismatch, and resume verified")
