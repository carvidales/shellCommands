import { Controller } from "@hotwired/stimulus"

// Keeps the live log exact. Output that arrives between rendering the page
// and subscribing to the stream would otherwise be lost, so once the stream
// connects we fetch the current log and status once. Every streamed chunk is
// a <span data-start data-end> with its character range in the log: chunks
// we already have are dropped, and a gap triggers another fetch.
export default class extends Controller {
  static targets = ["log"]
  static values = { length: Number, url: String }

  connect() {
    this.observer = new MutationObserver((mutations) => this.chunksAdded(mutations))
    this.observer.observe(this.logTarget, { childList: true })
    this.watchStreamSource()
  }

  disconnect() {
    this.observer.disconnect()
    this.sourceObserver?.disconnect()
  }

  // turbo-rails sets a `connected` attribute once the subscription is live.
  watchStreamSource() {
    const source = document.querySelector("turbo-cable-stream-source")
    if (!source) return
    if (source.hasAttribute("connected")) return this.resync()
    this.sourceObserver = new MutationObserver(() => {
      if (source.hasAttribute("connected")) {
        this.sourceObserver.disconnect()
        this.resync()
      }
    })
    this.sourceObserver.observe(source, { attributes: true, attributeFilter: ["connected"] })
  }

  chunksAdded(mutations) {
    if (this.syncing) return
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (!(node instanceof HTMLElement) || !node.dataset.end) continue
        const start = Number(node.dataset.start)
        const end = Number(node.dataset.end)
        if (end <= this.lengthValue) {
          node.remove()
        } else if (start > this.lengthValue) {
          this.resync()
        } else {
          this.lengthValue = end
        }
      }
    }
  }

  async resync() {
    if (this.syncing) return
    this.syncing = true
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const { log, length, status_html } = await response.json()

      // Keep chunks that arrived after the server read the log.
      const newer = [...this.logTarget.querySelectorAll("span[data-end]")]
        .filter((span) => Number(span.dataset.start) >= length)
        .sort((a, b) => Number(a.dataset.start) - Number(b.dataset.start))
      this.logTarget.textContent = log
      let current = length
      for (const span of newer) {
        if (Number(span.dataset.start) !== current) break
        this.logTarget.append(span)
        current = Number(span.dataset.end)
      }
      this.lengthValue = current

      const status = this.element.querySelector("[id$='_status']")
      if (status) status.outerHTML = status_html
    } finally {
      this.syncing = false
    }
  }
}
