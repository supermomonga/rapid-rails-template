import { Controller } from "@hotwired/stimulus"
import "billing/base_account"

export default class extends Controller {
  static targets = ["chain", "prepare", "authorize", "review", "terms", "message", "contractLink"]
  static values = { createUrl: String, planId: Number, appName: String, contract: Object, labels: Object }

  connect() {
    this.contract = this.hasContractValue ? this.contractValue : null
    if (this.contract) this.showReview()
  }

  async prepare(event) {
    event.preventDefault()
    this.prepareTarget.disabled = true
    this.messageTarget.textContent = this.labelsValue.connecting
    try {
      const chainId = Number(this.chainTarget.value)
      const provider = this.provider()
      const accounts = await provider.request({ method: "eth_requestAccounts" })
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: `0x${chainId.toString(16)}` }] })
      const connectedChain = await provider.request({ method: "eth_chainId" })
      if (Number(connectedChain) !== chainId) throw new Error(this.labelsValue.wrongChain)
      this.contract = await this.post(this.createUrlValue, { subscription: { plan_id: this.planIdValue, chain_id: chainId, payer_address: accounts[0] } })
      this.showReview()
      this.messageTarget.textContent = this.labelsValue.review
      this.authorizeTarget.focus()
    } catch (error) {
      this.messageTarget.textContent = error.message || this.labelsValue.failed
      this.prepareTarget.disabled = false
    }
  }

  async authorize(event) {
    event.preventDefault()
    this.authorizeTarget.disabled = true
    this.messageTarget.textContent = this.labelsValue.signing
    try {
      const provider = this.provider()
      const accounts = await provider.request({ method: "eth_requestAccounts" })
      const data = this.contract.typed_data
      if (accounts[0]?.toLowerCase() !== data.message.account.toLowerCase()) throw new Error(this.labelsValue.wrongWallet)
      const chainId = Number(data.domain.chainId)
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: `0x${chainId.toString(16)}` }] })
      if (Number(await provider.request({ method: "eth_chainId" })) !== chainId) throw new Error(this.labelsValue.wrongChain)
      const signature = await provider.request({ method: "eth_signTypedData_v4", params: [accounts[0], JSON.stringify(data)] })
      const result = await this.post(this.contract.authorize_path, { signature })
      window.location.assign(result.subscription_path)
    } catch (error) {
      this.messageTarget.textContent = error.message || this.labelsValue.failed
      this.authorizeTarget.disabled = false
    }
  }

  provider() {
    this.sdk ||= window.createBaseAccountSDK({ appName: this.appNameValue, appChainIds: [42161, 8453, 1, 137] })
    return this.sdk.getProvider()
  }

  showReview() {
    this.prepareTarget.hidden = true
    this.chainTarget.disabled = true
    this.reviewTarget.hidden = false
    this.termsTarget.textContent = this.contract.review
    this.contractLinkTarget.href = this.contract.subscription_path
    this.contractLinkTarget.hidden = false
  }

  async post(path, body) {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content }, body: JSON.stringify(body) })
    if (!response.headers.get("content-type")?.includes("application/json")) throw new Error(this.labelsValue.failed)
    const result = await response.json()
    if (!response.ok) throw new Error(result.error || this.labelsValue.failed)
    return result
  }
}
